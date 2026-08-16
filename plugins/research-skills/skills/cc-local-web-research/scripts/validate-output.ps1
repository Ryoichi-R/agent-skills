<#
.SYNOPSIS
    cc-local-web-research の Markdown 出力ファイルが Phase D 検証ルールに準拠しているか検証する。

.DESCRIPTION
    SKILL.md Phase D「スキーマ検証手順」を自動化したバリデータ。
    出力ファイルの書き込み確定前（.tmp 状態）に呼び出し、検証失敗時は exit code 1 を返す。

    検証内容:
      1. 末尾 JSON コメント `<!-- JSON: {...} -->` を抽出
      2. 抽出 JSON を `output-schema.json` で全項目検証（Test-Json -Schema）。
         セクション順序・additionalProperties・url 形式・metadata oneOf・conflict_resolution の
         if/then、および source_type 別必須（web→url / local→path+lines）はすべてスキーマが担保する
      3. Markdown 本文 `## 1. ローカル情報` セクションに、ローカル引用の正規表現が 1 件以上マッチすること
      4. 同セクションに、VS Code で開ける `vscode://file/...:<line>` 補助リンクがローカル引用数以上マッチすること
         （JSON Schema の対象外のため手書き検証として存続）
      5. 例外: `sources` に local エントリ 0 件、または本文中に「ローカル資料に該当情報なし」を含む場合は
         引用フォーマット検証（項目3）をスキップ

.PARAMETER Path
    検証対象の Markdown ファイルパス（通常は `.tmp` 状態のファイル）。

.OUTPUTS
    検証成功時 exit 0、失敗時 exit 1。stderr にエラー詳細を JSON で出力する。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot '_citation-format.ps1')

function Write-ValidationError {
    param([string]$Code, [string]$Message, [hashtable]$Context = @{})
    $err = [ordered]@{
        level   = "error"
        code    = $Code
        message = $Message
        context = $Context
    }
    [Console]::Error.WriteLine(($err | ConvertTo-Json -Compress -Depth 6))
}

if (-not (Test-Path $Path)) {
    Write-ValidationError -Code "file_not_found" -Message "対象ファイルが存在しません" -Context @{ path = $Path }
    exit 1
}

$content = Get-Content $Path -Raw -Encoding utf8
if ([string]::IsNullOrWhiteSpace($content)) {
    Write-ValidationError -Code "empty_file" -Message "対象ファイルが空です" -Context @{ path = $Path }
    exit 1
}

# ── 1. 末尾 JSON コメントの抽出 ──
$jsonMatch = [regex]::Match($content, '<!-- JSON: (\{.*\}) -->', [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $jsonMatch.Success) {
    Write-ValidationError -Code "missing_json_comment" -Message "末尾の <!-- JSON: {...} --> コメントが見つかりません" -Context @{ path = $Path }
    exit 1
}

$jsonText = $jsonMatch.Groups[1].Value
try {
    $payload = $jsonText | ConvertFrom-Json
} catch {
    Write-ValidationError -Code "invalid_json" -Message "JSON コメントのパースに失敗しました" -Context @{ path = $Path; error = "$_" }
    exit 1
}

# ── 2. JSON Schema 全項目検証（Test-Json -Schema / output-schema.json） ──
# セクション順序・additionalProperties・url 形式・metadata oneOf・conflict_resolution の if/then・
# source_type 別必須（web→url / local→path+lines）はすべてスキーマが担保する。
$schemaPath = Join-Path $PSScriptRoot '..\references\output-schema.json'
if (-not (Test-Path $schemaPath)) {
    Write-ValidationError -Code "schema_not_found" -Message "output-schema.json が見つかりません" -Context @{ path = $schemaPath }
    exit 1
}
$schemaJson = Get-Content $schemaPath -Raw -Encoding utf8
$schemaErrors = $null
$schemaValid = $false
try {
    $schemaValid = Test-Json -Json $jsonText -Schema $schemaJson -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
} catch {
    $schemaValid = $false
    if (-not $schemaErrors) { $schemaErrors = $_ }
}
if (-not $schemaValid) {
    $detail = if ($schemaErrors) { @($schemaErrors | ForEach-Object { "$_" }) } else { @("schema validation failed") }
    Write-ValidationError -Code "schema_validation_failed" -Message "JSON が output-schema.json に準拠していません" -Context @{
        path   = $Path
        errors = $detail
    }
    exit 1
}

# ── 3. ローカル引用フォーマット検証（Markdown 本文。JSON Schema の対象外のため手書き） ──
# local 出典数は引用フォーマット検証の要否判定に使用する（schema 検証済みなので形状は信頼できる）。
$localSources = @($payload.sources | Where-Object { $_.source_type -eq 'local' })
# 例外条件: sources に local 0件、または本文中に「ローカル資料に該当情報なし」
$noLocalLiteral = $content -match 'ローカル資料に該当情報なし'
if ($localSources.Count -eq 0 -or $noLocalLiteral) {
    # 検証スキップ
    exit 0
}

# 「## 1. ローカル情報」セクションを抽出（「## 2. Web情報」直前まで）
$sectionMatch = [regex]::Match($content, '##\s*1\.\s*ローカル情報([\s\S]*?)(?=##\s*2\.\s*Web情報|##\s*2\.|\z)')
if (-not $sectionMatch.Success) {
    Write-ValidationError -Code "missing_local_section" -Message "## 1. ローカル情報 セクションが見つかりません" -Context @{ path = $Path }
    exit 1
}

$localSection = $sectionMatch.Groups[1].Value

# 正規表現: 解決済み絶対パスを持つ [name.md](...#Lx-Ly) (Lx-Ly)
$citationPattern = Get-LocalCitationPattern
$citationMatches = [regex]::Matches($localSection, $citationPattern)

if ($citationMatches.Count -eq 0) {
    Write-ValidationError -Code "citation_format_violation" -Message "ローカル情報セクションに新フォーマットの引用（リンク内行番号アンカー + L表記併記）が 1 件も検出されません" -Context @{
        path = $Path
        pattern = $citationPattern
        local_sources_count = $localSources.Count
    }
    exit 1
}

# 正規表現: 解決済み絶対パスを持つ [VS Codeで開く](vscode://file/.../name.md:x[:y])
$vscodeLinkPattern = Get-VsCodeCitationLinkPattern
$vscodeLinkMatches = [regex]::Matches($localSection, $vscodeLinkPattern)

if ($vscodeLinkMatches.Count -lt $citationMatches.Count) {
    Write-ValidationError -Code "vscode_link_format_violation" -Message "ローカル情報セクションの VS Code 補助リンク数がローカル引用数に足りません" -Context @{
        path = $Path
        pattern = $vscodeLinkPattern
        citation_count = $citationMatches.Count
        vscode_link_count = $vscodeLinkMatches.Count
        local_sources_count = $localSources.Count
    }
    exit 1
}

# 検証成功
exit 0
