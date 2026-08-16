#Requires -Version 7.0
<#
.SYNOPSIS
    条件付きクエリ理解。heuristic-first / LLM-second アーキテクチャ。
.DESCRIPTION
    CC_LWR_QUERY_UNDERSTANDING 環境変数で制御:
    - "off" (既定): 従来のスペース分割のみ
    - "auto": heuristic-first, 曖昧時のみ LLM
    - "always": 常時 LLM（テスト用）

    heuristic 処理: 辞書ベース同義語展開 + ルールベース intent 分類
    LLM 処理: 曖昧性スコア >= 0.5 の場合のみ（auto モード時）
.PARAMETER Query
    検索クエリ文字列。
.PARAMETER SynonymDictPath
    同義語辞書 JSON ファイルのパス。
.OUTPUTS
    stdout に単一行の JSON を出力する（pwsh -File 起動でのプロセス境界対応）。
    needs_llm / llm_prompt_hint は全経路で常時出力する:
    {
        "intent":          "definition" | "howto" | "troubleshooting" | "factcheck" | "comparison" | "default",
        "synonyms":        ["word1","word2", ...],
        "ambiguity_score": 0.0 - 1.0,
        "source":          "off" | "heuristic" | "llm",
        "needs_llm":       false | true,
        "llm_prompt_hint": "" | "intent=...,ambiguity=...,tokens=..."
    }
    呼び出し側は `pwsh -NoProfile -File ... | ConvertFrom-Json` で受け取る。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Query,

    [string]$SynonymDictPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ── 結果は stdout に単一 JSON で出力する。needs_llm / llm_prompt_hint を常時補完 ──
function Write-QuResult {
    param([Parameter(Mandatory)][hashtable]$Result)
    if (-not $Result.ContainsKey('needs_llm')) { $Result['needs_llm'] = $false }
    if (-not $Result.ContainsKey('llm_prompt_hint')) { $Result['llm_prompt_hint'] = '' }
    # synonyms は要素数に関わらず常に JSON 配列で出力する（単一要素のアンラップ防止）
    if ($Result.ContainsKey('synonyms')) {
        $Result['synonyms'] = [object[]]@($Result['synonyms'])
    }
    Write-Output ($Result | ConvertTo-Json -Depth 6 -Compress)
}

$mode = if ($env:CC_LWR_QUERY_UNDERSTANDING) { $env:CC_LWR_QUERY_UNDERSTANDING } else { "off" }

# ── off モード: 即時返却 ──
if ($mode -eq "off") {
    Write-QuResult @{
        intent          = "default"
        synonyms        = @()
        ambiguity_score = 0.0
        source          = "off"
    }
    return
}

# ── 辞書パス解決 ──
if ([string]::IsNullOrEmpty($SynonymDictPath)) {
    $SynonymDictPath = Join-Path $PSScriptRoot "..\references\synonym-dict.json"
}

# ── 曖昧性スコア算出 ──
function Get-QueryAmbiguity {
    param([string]$Q)
    $tokens = $Q -split '\s+'
    $score = 0.0
    if ($tokens.Count -gt 5) { $score += 0.3 }
    if ($Q -match '(なぜ|どう|どの|いつ|why|how|which|when)') { $score += 0.2 }
    if ($Q -match '(vs|比較|違い|差|compare|difference)') { $score += 0.2 }
    if ($Q -match '(ない|しない|not|without|except)') { $score += 0.15 }
    if ($Q -match '(ベスト|おすすめ|best|recommend)') { $score += 0.15 }
    return [Math]::Min($score, 1.0)
}

# ── heuristic intent 分類 ──
function Get-HeuristicIntent {
    param([string]$Q)
    $qLower = $Q.ToLower()
    if ($qLower -match '(とは|定義|definition|what is|meaning)') { return "definition" }
    if ($qLower -match '(方法|やり方|手順|how to|howto|手法|使い方)') { return "howto" }
    if ($qLower -match '(エラー|error|障害|失敗|fix|解決|troubleshoot|デバッグ|debug)') { return "troubleshooting" }
    if ($qLower -match '(vs|比較|違い|差|compare|difference|どちらが)') { return "comparison" }
    if ($qLower -match '(本当|正しい|事実|fact|確認|verify)') { return "factcheck" }
    return "default"
}

# ── heuristic 同義語展開 ──
function Get-HeuristicSynonyms {
    param([string]$Q, [string]$DictPath)
    $synonyms = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path $DictPath)) {
        Write-Warning "[query_understanding] synonym dict not found: $DictPath"
        return @()
    }

    try {
        $dict = Get-Content $DictPath -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        Write-Warning "[query_understanding] synonym dict parse error: $_"
        return @()
    }

    $qLower = $Q.ToLower()
    $tokens = $qLower -split '\s+'

    foreach ($prop in $dict.PSObject.Properties) {
        $key = $prop.Name.ToLower()
        $found = $false
        foreach ($token in $tokens) {
            if ($token.Contains($key) -or $key.Contains($token)) {
                $found = $true
                break
            }
        }
        if ($found) {
            foreach ($syn in $prop.Value) {
                $synLower = $syn.ToLower()
                if ($synLower -notin $tokens -and -not $synonyms.Contains($synLower)) {
                    $synonyms.Add($synLower)
                    if ($synonyms.Count -ge 5) { break }
                }
            }
        }
        if ($synonyms.Count -ge 5) { break }
    }
    return $synonyms.ToArray()
}

# ── LLM 不要判定 ──
$ambiguity = Get-QueryAmbiguity -Q $Query
$tokens = $Query -split '\s+'

$skipLlm = $false
if ($tokens.Count -le 3 -and $ambiguity -lt 0.3) { $skipLlm = $true }
if ($Query -match '^[a-zA-Z0-9_\-\.\/\\]+$') { $skipLlm = $true }  # 単一の固有名詞/ファイル名
if ($ambiguity -lt 0.5 -and $mode -eq "auto") { $skipLlm = $true }

# ── heuristic 処理 ──
$intent = Get-HeuristicIntent -Q $Query
$synonyms = Get-HeuristicSynonyms -Q $Query -DictPath $SynonymDictPath

# ── LLM フォールバック（auto で曖昧性高い場合、または always） ──
if (($mode -eq "always") -or ($mode -eq "auto" -and -not $skipLlm)) {
    # LLM は外部呼び出し（SKILL.md の Phase A でサブエージェントが実行）
    # ここでは LLM 呼び出しのためのプロンプト情報を返す
    Write-QuResult @{
        intent           = $intent
        synonyms         = $synonyms
        ambiguity_score  = $ambiguity
        source           = "heuristic"
        needs_llm        = $true
        llm_prompt_hint  = "intent=$intent, ambiguity=$ambiguity, tokens=$($tokens -join ',')"
    }
    return
}

Write-QuResult @{
    intent          = $intent
    synonyms        = $synonyms
    ambiguity_score = $ambiguity
    source          = "heuristic"
}
return
