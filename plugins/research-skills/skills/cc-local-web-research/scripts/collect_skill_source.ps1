<#
.SYNOPSIS
    skill-source ディレクトリをスキャンし、クエリに関連するローカル資料を取得する。

.DESCRIPTION
    インデックスベースの差分更新 + 2段階検索でファイルを高速に検索する。
    Phase 1: インデックスの keywords/keywordFreq でスコアリングし候補を絞り込む
    Phase 2: 上位候補のみ全文読み込みしスニペットを抽出する

.PARAMETER Query
    検索クエリ文字列。スペース区切りで複数キーワードを指定可能。

.PARAMETER SourceRoot
    スキャン対象のルートディレクトリ。環境変数 CC_LWR_SOURCE_ROOT、未設定時はユーザーhome直下の skill-source（$HOME/skill-source）。

.PARAMETER MaxFiles
    返却する最大ファイル数。デフォルトは 8。

.PARAMETER MaxCharsPerFile
    ファイルごとの最大取得文字数。デフォルトは 1200。

.PARAMETER IndexPath
    インデックスファイルのパス。空=自動(repo root の .cache/cc-local-web-research/search-index-<hash>.json)。
    環境変数 CC_LWR_CACHE_DIR で cache ディレクトリを、CC_REPO_ROOT で repo root を上書きできる。

.PARAMETER ForceReindex
    強制再構築フラグ。指定時は TTL を無視して再列挙・差分更新する。

.PARAMETER IndexFreshnessTtlSeconds
    インデックス鮮度 TTL（秒）。既定 600。index の updatedAt からの経過が TTL 未満なら
    再帰列挙・per-file stat・再ハッシュをスキップし既存 index のみで検索する。0 で TTL 無効（従来挙動）。

.PARAMETER FullAuditIntervalHours
    全件ハッシュ監査の間隔（時間）。デフォルトは 24。

.PARAMETER SearchMode
    Indexed（既定）または FullText。FullText はインデックスの候補選別を使わず、
    許可された全資料を走査し、結果をページングして返す。

.PARAMETER Offset
    FullText の返却開始位置。MaxFiles と組み合わせて継続取得する。

.PARAMETER IgnoreSourcePreference
    明示的な旧版・時点指定の検索では、資料ルート内の優先順を適用しない。

.OUTPUTS
    JSON 文字列を stdout に出力する。
    スキーマ: { agent_type, status, sourceRoot, matches[], scanned_file_count, message }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Query,

    [string]$SourceRoot = $env:CC_LWR_SOURCE_ROOT,

    [ValidateRange(1, 100000)][int]$MaxFiles = 8,

    [ValidateRange(1, 1000000)][int]$MaxCharsPerFile = 1200,

    [string]$IndexPath = "",

    [switch]$ForceReindex,

    [int]$FullAuditIntervalHours = 24,

    [int]$IndexFreshnessTtlSeconds = 600,

    [ValidateSet('Indexed', 'FullText')]
    [string]$SearchMode = 'Indexed',

    [ValidateRange(0, 2147483647)]
    [int]$Offset = 0,

    [hashtable]$ScoreWeightsOverride = @{},

    [string[]]$SynonymKeywords = @(),

    [switch]$IgnoreSourcePreference
)
# Validate the actual I/O operands with the shared secret-file policy.
. (Join-Path $PSScriptRoot '_web-cache-shared.ps1')
function Assert-ScriptFileIoPath {
    param([AllowNull()][AllowEmptyCollection()][AllowEmptyString()][object]$Path, [switch]$AllowWildcards, [switch]$Recurse)
    return (Assert-FileIoPathAllowed -Path $Path -AllowWildcards:$AllowWildcards -Recurse:$Recurse -SecretPathTest { param($candidatePath) Test-SecretFilePath -FilePath $candidatePath })
}
foreach ($guardParameter in @($PSBoundParameters.Keys)) {
    if ($guardParameter -match '(?i)(paths?|roots?|files?|dirs?|directories|folders?)$') {
        $null = Assert-ScriptFileIoPath -Path $PSBoundParameters[$guardParameter]
    }
}


Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module (Join-Path $PSScriptRoot 'ResearchContext.psm1') -Force
$script:SourcePreferenceGroups = @()
$script:SourcePreferenceFingerprint = ''
. (Join-Path $PSScriptRoot 'Currentness.ps1')
$script:CorpusCurrentness = $null

# ── 定数 ──
# WI-2: dirMtimes スキップ機構を撤去（NTFS では内容上書きで親 dir mtime が不変のため
# 既存ファイル編集を full audit まで見逃す）。高速パスは TTL + mtime/size 一次フィルタ +
# contentHash 最終判定に一本化。schema 互換のため SCHEMA_VERSION を 3 へ（旧 index は full rebuild）。
$SCHEMA_VERSION = 3
$LOCK_TIMEOUT_SEC = 10
$STALE_TMP_MINUTES = 60

$ScoreWeights = @{
    FileNameExact     = 3; FileNameSub     = 2
    DirExact          = 2; DirSub          = 1
    SummaryExact      = 2; SummarySub      = 1
    BM25_k1           = 1.2; BM25_b        = 0.75
    # 後方互換: BM25 有効時は無視されるが定義は残す
    KeywordFreqCap    = 10; KeywordFreqSubCap = 5
}

# ScoreWeights パラメータ上書き（キー検証: 未知キーは警告+無視、値域: 0以上の整数）
if ($ScoreWeightsOverride.Count -gt 0) {
    foreach ($key in $ScoreWeightsOverride.Keys) {
        if (-not $ScoreWeights.ContainsKey($key)) {
            Write-Warning "[score_weights] 未知のキー '$key' は無視されます"
            continue
        }
        $val = $ScoreWeightsOverride[$key]
        if (($val -is [int] -or $val -is [double]) -and $val -ge 0) {
            $ScoreWeights[$key] = $val
        } else {
            Write-Warning "[score_weights] キー '$key' の値 '$val' は 0 以上の数値である必要があります"
        }
    }
}

# ── repo root 解決（CWD 非依存: 裸 git rev-parse は使わない） ──
# 裸の `git rev-parse` は CWD 依存（別 repo を CWD にすると誤った root を拾う）。
# 必ず `git -C $PSScriptRoot` を使い、失敗時は $PSScriptRoot 基準で解決する。
function Resolve-RepoRoot {
    # 1. 明示上書き（テスト / 特殊環境用）
    if ($env:CC_REPO_ROOT -and (Test-Path $env:CC_REPO_ROOT)) {
        return (Resolve-Path (Assert-ScriptFileIoPath -Path ($env:CC_REPO_ROOT) -AllowWildcards)).Path
    }
    # 2. git -C $PSScriptRoot（CWD 非依存）
    try {
        $r = git -C $PSScriptRoot rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $r -and (Test-Path $r)) {
            return (Resolve-Path (Assert-ScriptFileIoPath -Path ($r) -AllowWildcards)).Path
        }
    } catch { }
    # 3. $PSScriptRoot から .git を上方探索
    $dir = $PSScriptRoot
    while ($dir) {
        if (Test-Path (Join-Path $dir ".git")) { return (Resolve-Path (Assert-ScriptFileIoPath -Path ($dir) -AllowWildcards)).Path }
        $parent = [IO.Path]::GetDirectoryName($dir)
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    # 4. フォールバック: $PSScriptRoot の 4 階層上
    return (Resolve-Path (Assert-ScriptFileIoPath -Path ((Join-Path $PSScriptRoot "..\..\..\..")) -AllowWildcards) -ErrorAction SilentlyContinue).Path
}

# SourceRoot 文字列の cache key 用ハッシュ。ファイル内容そのもののハッシュとは別物。
# 正規化規則: 区切り統一(\→/) → 末尾スラッシュ除去 → 小文字化 → UTF-8(no BOM) → SHA256 先頭16桁。
function Get-SourceRootCacheKey {
    param([string]$Path)
    $norm = ($Path -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($norm)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hashBytes = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    $hex = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    return $hex.Substring(0, 16)
}

# 既定 IndexPath を repo root 配下の workspace cache に解決する（G: には書かない）。
function Resolve-DefaultIndexPath {
    param([string]$RepoRoot, [string]$ResolvedRoot)
    $fileName = "search-index-$(Get-SourceRootCacheKey -Path $ResolvedRoot).json"
    # cache base: 環境変数上書き > <repoRoot>/.cache/cc-local-web-research
    $cacheDir = if ($env:CC_LWR_CACHE_DIR) { $env:CC_LWR_CACHE_DIR }
                elseif ($RepoRoot) { Join-Path $RepoRoot ".cache/cc-local-web-research" }
                else { $null }
    if ($cacheDir) {
        try {
            if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path (Assert-ScriptFileIoPath -Path ($cacheDir) -AllowWildcards) -Force | Out-Null }
            return (Join-Path $cacheDir $fileName)
        } catch {
            Write-Warning "[cache_dir_failed] dir=$cacheDir error=$_ → temp fallback"
        }
    }
    # フォールバック: temp（G: には書かない）
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) "cc-local-web-research"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path (Assert-ScriptFileIoPath -Path ($tempDir) -AllowWildcards) -Force | Out-Null }
    return (Join-Path $tempDir $fileName)
}

$repoRoot = Resolve-RepoRoot
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = Join-Path $HOME 'skill-source' }
# A-6: repo root 解決失敗でもここでは終了しない。既定 IndexPath は Resolve-DefaultIndexPath が
# temp へフォールバックする（G: には書かない）。相対 SourceRoot だけは repoRoot 基準でしか
# 解決できないため、repoRoot が無く SourceRoot も相対の場合に限りエラー終了する。
if (-not [IO.Path]::IsPathRooted($SourceRoot)) {
    if (-not $repoRoot) {
        Write-Error "repoRoot の解決に失敗し、相対 SourceRoot '$SourceRoot' を解決できません。git リポジトリ内で実行するか、SourceRoot に絶対パスを指定してください。"
        exit 1
    }
    $SourceRoot = Join-Path $repoRoot $SourceRoot
}

# ── Get-SnippetLineRange: snippet の文字位置から 1-indexed の開始・終了行を算出 ──
function Get-SnippetLineRange {
    param(
        [string]$Content,        # 元のファイル全文（snippetMaxChars で切り詰められる前）
        [int]$CharStart,         # snippet の開始文字位置（0-indexed）
        [int]$CharEnd            # snippet の終了文字位置（排他、0-indexed）
    )
    if ([string]::IsNullOrEmpty($Content)) {
        return @{ start = 1; end = 1 }
    }
    $startLine = 1
    $upperStart = [Math]::Min($CharStart, $Content.Length)
    for ($i = 0; $i -lt $upperStart; $i++) {
        if ($Content[$i] -eq "`n") { $startLine++ }
    }
    $endLine = $startLine
    $upperEnd = [Math]::Min($CharEnd, $Content.Length)
    for ($i = $upperStart; $i -lt $upperEnd; $i++) {
        if ($Content[$i] -eq "`n") { $endLine++ }
    }
    return @{ start = $startLine; end = $endLine }
}


# Phase 1 also accepts reverse substring matches in truncated index keywords.
# Before returning any candidate, require a query keyword (including supported
# subwords/synonyms) in the body or searchable metadata, regardless of rerank limits.
function Test-IndexedCandidateMatch {
    param($Entry, [string]$ContentLower, [string[]]$Keywords)
    $fileName = ([string]$Entry.fileNameNormalized).ToLower()
    $directory = (@($Entry.dirSegments) -join ' ').ToLower()
    $summary = ([string]$Entry.summary).ToLower()
    foreach ($keyword in $Keywords) {
        if ($ContentLower.Contains($keyword) -or $fileName.Contains($keyword) -or
            $directory.Contains($keyword) -or $summary.Contains($keyword)) {
            return $true
        }
    }
    return $false
}

# User-approved edition preferences are data, bound to exact corpus files.
# Other documents keep their relative order and scores; dates alone never boost.
function Read-SourcePreferenceGroups {
    param([string]$Root)
    $path = Join-Path $Root '.research-policy/source-preferences.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $path = Assert-ResearchPath -Path $path -Root $Root
    if ((Get-Item -LiteralPath $path).Length -gt 1MB) { throw 'source_preference_policy_too_large' }
    $policy = Get-Content -LiteralPath (Assert-ScriptFileIoPath -Path ($path)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($policy.schema_version -ne '1.0' -or -not $policy.ContainsKey('groups')) { throw 'source_preference_schema_invalid' }
    $seen = @{}
    $groups = @()
    foreach ($group in @($policy.groups)) {
        if (-not $group.id -or -not $group.documents) { throw 'source_preference_group_invalid' }
        $documents = @()
        foreach ($entry in @($group.documents)) {
            $relative = ([string]$entry.path) -replace '\\', '/'
            if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)|[:\r\n]') { throw 'source_preference_path_invalid' }
            if ($seen.ContainsKey($relative)) { throw 'source_preference_path_repeated' }
            if ($entry.role -notin @('preferred', 'related_older', 'related_date_unknown')) { throw 'source_preference_role_invalid' }
            foreach ($field in @('edition', 'note')) {
                if (-not $entry[$field] -or ([string]$entry[$field]).Length -gt 256 -or $entry[$field] -match '[\r\n]') { throw 'source_preference_label_invalid' }
            }
            if ($entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'source_preference_hash_invalid' }
            $full = Assert-ResearchPath -Path (Join-Path $Root $relative) -Root $Root
            if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne $entry.sha256) { throw 'source_preference_hash_mismatch' }
            $seen[$relative] = $true
            $rawMatchCount = 0
            if ($entry.role -eq 'preferred') {
                $content = Get-Content -LiteralPath (Assert-ScriptFileIoPath -Path ($full)) -Raw -Encoding utf8
                foreach ($term in @($Query -split '\s+' | Where-Object { $_ })) {
                    $rawMatchCount += [regex]::Matches($content, [regex]::Escape($term), [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
                }
            }
            $documents += @{ path = $relative; role = $entry.role; edition = $entry.edition; note = $entry.note; rawMatchCount = $rawMatchCount }
        }
        if (@($documents | Where-Object role -eq 'preferred').Count -eq 0) { throw 'source_preference_preferred_missing' }
        $groups += @{ id = $group.id; documents = $documents }
    }
    $script:SourcePreferenceFingerprint = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $groups
}

function Get-SourcePreferenceOrder {
    param([AllowEmptyCollection()][object[]]$Matches, [string]$PathProperty = 'path')
    $ordered = @($Matches)
    if ($IgnoreSourcePreference -or $script:SourcePreferenceGroups.Count -eq 0) { return $ordered }
    $preferred = @($script:SourcePreferenceGroups | ForEach-Object { $_.documents } | Where-Object { $_.role -eq 'preferred' -and $_.rawMatchCount -gt 0 } | ForEach-Object path)
    $first = @()
    $remaining = @()
    foreach ($match in $ordered) {
        $relative = ([string]$match.$PathProperty) -replace '\\', '/'
        if ($relative -in $preferred) { $first += $match } else { $remaining += $match }
    }
    return @($first) + @($remaining)
}

function Get-SourcePreferenceNote {
    param([AllowEmptyCollection()][object[]]$Matches)
    $paths = @($Matches | ForEach-Object { ([string]$_.path) -replace '\\', '/' })
    $notes = @()
    foreach ($group in $script:SourcePreferenceGroups) {
        foreach ($entry in $group.documents) {
            if ($entry.path -in $paths) {
                $notes += "$($entry.path): $($entry.role), $($entry.edition), $($entry.note)"
            }
        }
    }
    if ($notes.Count -gt 0) {
        $mode = if ($IgnoreSourcePreference) { '版指定検索: 優先並べ替え無効' } else { '原文で検索語が一致した利用者指定資料を先に参照' }
        return "[資料の版: $mode] " + ($notes -join '; ')
    }
    return ''
}

# ── 結果オブジェクトのヘルパー ──
function New-Result {
    param(
        [string]$Status,
        [string]$ResolvedRoot,
        [array]$MatchList = @(),
        [int]$ScannedCount = 0,
        [string]$Message = "",
        [string]$Mode = $SearchMode,
        [int]$CandidateCount = 0,
        [int]$ReturnedCount = 0,
        [bool]$Truncated = $false,
        [AllowNull()][object]$NextOffset = $null,
        [array]$ReadFailures = @(),
        [int]$UnsupportedFileCount = 0,
        [string]$CorpusFingerprint = ''
    )
    if ($null -eq $MatchList) { $MatchList = @() }
    $preferenceNote = Get-SourcePreferenceNote -Matches $MatchList
    if ($preferenceNote) { $Message = (@($Message, $preferenceNote) | Where-Object { $_ }) -join "`n" }
    $currentnessNote = Get-CorpusCurrentnessNote -Policy $script:CorpusCurrentness -Matches $MatchList -Query $Query
    if ($currentnessNote) { $Message = (@($Message, $currentnessNote) | Where-Object { $_ }) -join "`n" }
    $result = @{
        agent_type         = "local"
        status             = $Status
        sourceRoot         = $ResolvedRoot
        matches            = $MatchList
        scanned_file_count = $ScannedCount
        message            = $Message
    }
    if ($Mode -eq 'FullText') {
        $result += @{
        schema_version     = 'fulltext-1.0'
        searchMode         = $Mode
        candidate_count    = $CandidateCount
        returned_count     = $ReturnedCount
        truncated          = $Truncated
        next_offset        = $NextOffset
        read_failures      = @($ReadFailures)
        unsupported_file_count = $UnsupportedFileCount
        corpus_fingerprint = $CorpusFingerprint
        }
    }
    $result | ConvertTo-Json -Depth 4 -Compress
}

# ── Get-ExcludedPatterns: 除外対象パターンを一元管理 ──
function Get-ExcludedPatterns {
    @{
        FileNames   = @('.env*', 'secrets.*', 'credentials.*', '.search-index.json', '.search-index.lock',
                        '.generate-summaries-failures.json')
        FileGlobs   = @('*.tmp.*.json', '*.meta.yaml', '*.bak')
        DirPatterns = @('^\.')  # 隠しディレクトリ
    }
}

# ── FullText 検索 ──
function Invoke-FullTextSearch {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo[]]$Files,
        [Parameter(Mandatory)][string]$ResolvedRoot,
        [Parameter(Mandatory)][string[]]$Keywords,
        [Parameter(Mandatory)][int]$Limit,
        [Parameter(Mandatory)][int]$Start,
        [Parameter(Mandatory)][int]$SnippetLimit,
        [Parameter(Mandatory)][string]$Mode,
        [int]$UnsupportedFileCount = 0
    )

    $hits = [System.Collections.Generic.List[hashtable]]::new()
    $readFailures = [System.Collections.Generic.List[string]]::new()
    $fingerprintParts = [System.Collections.Generic.List[string]]::new()
    if ($script:CorpusCurrentness) { $fingerprintParts.Add("currentness:$($script:CorpusCurrentness.fingerprint)") }
    if ($script:SourcePreferenceFingerprint) { $fingerprintParts.Add("policy:$($script:SourcePreferenceFingerprint)|ignore:$IgnoreSourcePreference") }

    foreach ($file in $Files) {
        $relativePath = $file.FullName.Substring($ResolvedRoot.Length + 1) -replace '\\', '/'
        $fingerprintParts.Add("$relativePath|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)")
        try {
            Assert-ResearchPath -Path $file.FullName -Root $ResolvedRoot | Out-Null
            $content = Get-Content -LiteralPath (Assert-ScriptFileIoPath -Path ($file.FullName)) -Raw -Encoding utf8 -ErrorAction Stop
            Assert-ResearchSafeText -Text $content
            if ([string]::IsNullOrEmpty($content)) { continue }
            $lower = $content.ToLowerInvariant()
            $matchedTerms = [System.Collections.Generic.List[string]]::new()
            $score = 0
            $firstIndex = -1
            foreach ($keyword in $Keywords) {
                if ([string]::IsNullOrWhiteSpace($keyword)) { continue }
                $count = ([regex]::Matches($lower, [regex]::Escape($keyword))).Count
                if ($count -gt 0) {
                    $matchedTerms.Add($keyword)
                    $score += $count
                    $idx = $lower.IndexOf($keyword, [StringComparison]::Ordinal)
                    if ($firstIndex -lt 0 -or ($idx -ge 0 -and $idx -lt $firstIndex)) { $firstIndex = $idx }
                }
            }
            if ($score -le 0) { continue }

            $snippetStart = if ($firstIndex -ge 0) { [Math]::Max(0, $firstIndex - 120) } else { 0 }
            $snippetEnd = [Math]::Min($content.Length, $snippetStart + $SnippetLimit)
            $snippet = $content.Substring($snippetStart, $snippetEnd - $snippetStart).Trim()
            $lineRange = Get-SnippetLineRange -Content $content -CharStart $snippetStart -CharEnd $snippetEnd
            $contentHash = ''
            try {
                $contentHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            } catch { $contentHash = '' }

            $hits.Add(@{
                path             = $relativePath
                score            = $score
                matchCount       = $score
                matchedTerms     = @($matchedTerms)
                snippet          = $snippet
                snippetStartLine = $lineRange.start
                snippetEndLine   = $lineRange.end
                modifiedAt       = $file.LastWriteTimeUtc.ToString('o')
                contentHash      = $contentHash
            })
        }
        catch {
            $readFailures.Add($relativePath)
        }
    }

    $sorted = @($hits | Sort-Object @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.path }; Descending = $false })
    $sorted = @(Get-SourcePreferenceOrder -Matches $sorted)
    $candidateCount = $sorted.Count
    $returned = @($sorted | Select-Object -Skip $Start -First $Limit)
    $returnedCount = @($returned).Count
    $hasMore = ($Start + $returnedCount) -lt $candidateCount
    $next = if ($hasMore) { $Start + $returnedCount } else { $null }
    $fingerprintInput = ($fingerprintParts | Sort-Object) -join "`n"
    $fingerprint = if ($fingerprintInput) {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($fingerprintInput)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    } else { '' }
    $status = if ($readFailures.Count -gt 0) { 'partial' } elseif ($candidateCount -eq 0) { 'empty' } else { 'ok' }
    $message = if ($readFailures.Count -gt 0) { '一部資料を読み取れませんでした。' } else { '' }
    return New-Result -Status $status -ResolvedRoot $ResolvedRoot -MatchList $returned -ScannedCount $Files.Count `
        -Message $message -Mode $Mode -CandidateCount $candidateCount -ReturnedCount $returnedCount `
        -Truncated $hasMore -NextOffset $next -ReadFailures @($readFailures) `
        -UnsupportedFileCount $UnsupportedFileCount -CorpusFingerprint $fingerprint
}

# ── Extract-Keywords: 本文からキーワードを抽出 ──
function Extract-Keywords {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @{ keywords = @(); keywordFreq = @{} }
    }

    $contentLower = $Content.ToLower()

    # 文字種境界分割: CJK / カタカナ / ラテン文字+数字 / ひらがな連続
    $tokens = [regex]::Matches($contentLower,
        '[\p{IsCJKUnifiedIdeographs}]{2,}|[\p{IsKatakana}ー]{2,}|[a-z][a-z0-9_]{1,}|[\p{IsHiragana}]{3,}'
    )

    $freq = @{}
    foreach ($m in $tokens) {
        $word = $m.Value
        if ($freq.ContainsKey($word)) {
            $freq[$word]++
        } else {
            $freq[$word] = 1
        }
    }

    # ストップワード除去
    $stopWords = @('the','and','for','that','this','with','from','are','was','were','been',
                   'have','has','had','not','but','all','can','her','his','one','our',
                   'out','you','which','their','will','each','make','like','long',
                   'td','tr','th','thead','tbody','tfoot','table','rowspan','colspan',
                   'br','hr','div','span','img','src','href','alt','li','ul','ol',

                   'する','ある','いる','なる','れる','られる','できる','ない',
                   'こと','もの','ため','これ','それ','あれ','ここ','そこ',
                   'この','その','あの','また','および','ただし','なお','おいて',
                   'について','として','において','における','により')
    foreach ($sw in $stopWords) {
        $freq.Remove($sw)
    }

    # 上位語数（環境変数で設定可能、既定30）
    $topN = [int]$(if ($env:CC_LWR_TOP_KEYWORD_COUNT) { $env:CC_LWR_TOP_KEYWORD_COUNT } else { 30 })

    $topWords = $freq.GetEnumerator() |
        Sort-Object Value -Descending |
        Select-Object -First $topN

    $keywords = @($topWords | ForEach-Object { $_.Key })
    $keywordFreq = @{}
    foreach ($entry in $topWords) {
        $keywordFreq[$entry.Key] = $entry.Value
    }

    # tokenCount: 全トークン出現数の合計（BM25 の文書長正規化に使用）
    $tokenCount = 0
    foreach ($v in $freq.Values) { $tokenCount += $v }

    return @{ keywords = $keywords; keywordFreq = $keywordFreq; tokenCount = $tokenCount }
}

# ── Read-Frontmatter: .md ファイルの YAML frontmatter から summary を読取り ──
function Read-Frontmatter {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return $null }

    # BOM スキップ
    $text = $Content.TrimStart([char]0xFEFF)

    # +++ (TOML) や { (JSON) で始まるファイルは対象外
    if ($text.StartsWith('+++') -or $text.StartsWith('{')) { return $null }

    # --- で始まるか確認（改行を許容）
    if (-not ($text -match '^---\s*[\r\n]')) { return $null }

    # 2つ目の --- を探す
    $afterFirst = $text.Substring($text.IndexOf("`n") + 1)
    $endMatch = [regex]::Match($afterFirst, '(?m)^---\s*$')
    if (-not $endMatch.Success) { return $null }

    $fmBlock = $afterFirst.Substring(0, $endMatch.Index)

    # summary 行を探す
    $summaryMatch = [regex]::Match($fmBlock, '(?m)^summary\s*:\s*(.+)$')
    if (-not $summaryMatch.Success) { return $null }

    $val = $summaryMatch.Groups[1].Value.Trim()
    # 引用符除去
    if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
        ($val.StartsWith("'") -and $val.EndsWith("'"))) {
        $val = $val.Substring(1, $val.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    return $val
}

# ── Read-Sidecar: *.meta.yaml から summary を読取り ──
function Read-Sidecar {
    param(
        [System.IO.FileInfo]$File,
        [string]$ResolvedRoot
    )
    $sidecarPath = "$($File.FullName).meta.yaml"
    if (-not (Test-Path $sidecarPath)) { return @{ summary = $null; lastModified = $null } }

    try {
        $sidecarContent = Get-Content (Assert-ScriptFileIoPath -Path ($sidecarPath) -AllowWildcards) -Raw -Encoding utf8 -ErrorAction Stop
        $sidecarInfo = Get-Item $sidecarPath
        $summaryMatch = [regex]::Match($sidecarContent, '(?m)^summary\s*:\s*(.+)$')
        if ($summaryMatch.Success) {
            $val = $summaryMatch.Groups[1].Value.Trim()
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
                ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            return @{
                summary      = $val
                lastModified = $sidecarInfo.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }
    } catch {
        Write-Warning "[sidecar_read_failed] path=$sidecarPath error=$_"
    }
    return @{ summary = $null; lastModified = $null }
}

# ── Build-IndexEntry: 1ファイルからインデックスエントリを構築 ──
function Build-IndexEntry {
    param(
        [System.IO.FileInfo]$File,
        [string]$ResolvedRoot
    )

    $relativePath = $File.FullName.Substring($ResolvedRoot.Length + 1) -replace '\\', '/'
    $dirSegments = @()
    $parts = $relativePath -split '/'
    if ($parts.Count -gt 1) {
        $dirSegments = $parts[0..($parts.Count - 2)]
    }

    $fileNameNormalized = [IO.Path]::GetFileNameWithoutExtension($File.Name).ToLower()

    # タイトル抽出（.md の場合は先頭の # 行）
    $title = [IO.Path]::GetFileNameWithoutExtension($File.Name)
    $content = $null
    try {
        $content = Get-Content (Assert-ScriptFileIoPath -Path ($File.FullName) -AllowWildcards) -Raw -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Warning "[file_read_failed] path=$relativePath error=$_"
    }

    if ($content -and $File.Extension -eq '.md') {
        $titleMatch = [regex]::Match($content, '(?m)^#\s+(.+)$')
        if ($titleMatch.Success) {
            $title = $titleMatch.Groups[1].Value.Trim()
        }
    }

    # キーワード抽出
    $kwResult = Extract-Keywords -Content $content

    # summary 読取り（Phase 2）: サイドカー優先 → frontmatter
    $summary = ""
    $metadataLastModified = $null
    $sidecarResult = Read-Sidecar -File $File -ResolvedRoot $ResolvedRoot
    if ($sidecarResult.summary) {
        $summary = $sidecarResult.summary
        $metadataLastModified = $sidecarResult.lastModified
    } elseif ($content -and $File.Extension -eq '.md') {
        $fmSummary = Read-Frontmatter -Content $content
        if ($fmSummary) { $summary = $fmSummary }
    }

    # contentHash (SHA-256)
    $hashValue = ""
    try {
        $stream = [IO.File]::OpenRead((Assert-ScriptFileIoPath -Path ($File.FullName)))
        try {
            $sha = [Security.Cryptography.SHA256]::Create()
            $hashBytes = $sha.ComputeHash($stream)
            $hashValue = "sha256:" + ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLower()
        } finally {
            $stream.Close()
        }
    } catch {
        Write-Warning "[hash_compute_failed] path=$relativePath error=$_"
    }

    return @{
        lastModified         = $File.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
        sizeBytes            = $File.Length
        contentHash          = $hashValue
        title                = $title
        summary              = $summary
        metadataLastModified = $metadataLastModified
        dirSegments          = $dirSegments
        fileNameNormalized   = $fileNameNormalized
        keywords             = $kwResult.keywords
        keywordFreq          = $kwResult.keywordFreq
        tokenCount           = $kwResult.tokenCount
    }
}

# ── Update-SearchIndex: 差分更新でインデックスを管理 ──
function Update-SearchIndex {
    param(
        [string]$ResolvedRoot,
        [System.IO.FileInfo[]]$AllFiles,
        [string]$IdxPath,
        [bool]$Force
    )

    $lockPath = $IdxPath -replace '\.json$', '.lock'
    $lockStream = $null
    $usedStaleIndex = $false

    # 残留 tmp ファイルのクリーンアップ
    $tmpPattern = [IO.Path]::GetDirectoryName($IdxPath)
    $tmpFiles = Get-ChildItem -Path $tmpPattern -Filter ".search-index.tmp.*.json" -ErrorAction SilentlyContinue
    foreach ($tmp in $tmpFiles) {
        if ($tmp.CreationTimeUtc -lt (Get-Date).ToUniversalTime().AddMinutes(-$STALE_TMP_MINUTES)) {
            Write-Warning "[stale_tmp_cleanup] path=$($tmp.FullName)"
            Remove-Item (Assert-ScriptFileIoPath -Path ($tmp.FullName) -AllowWildcards) -Force -ErrorAction SilentlyContinue
        }
    }

    # 排他ロック取得
    try {
        $lockDir = [IO.Path]::GetDirectoryName($lockPath)
        if (-not (Test-Path $lockDir)) { New-Item -ItemType Directory -Path (Assert-ScriptFileIoPath -Path ($lockDir) -AllowWildcards) -Force | Out-Null }

        $deadline = (Get-Date).AddSeconds($LOCK_TIMEOUT_SEC)
        while ($true) {
            try {
                $lockStream = [IO.File]::Open((Assert-ScriptFileIoPath -Path ($lockPath)), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                break
            } catch {
                if ((Get-Date) -ge $deadline) {
                    throw "lock_timeout"
                }
                Start-Sleep -Milliseconds 200
            }
        }
    } catch {
        if ($_.Exception.Message -eq "lock_timeout" -or $_ -eq "lock_timeout") {
            Write-Warning "[lock_timeout_fallback] reason=lock_timeout"
            if (Test-Path $IdxPath) {
                try {
                    $staleData = Get-Content (Assert-ScriptFileIoPath -Path ($IdxPath) -AllowWildcards) -Raw -Encoding utf8 | ConvertFrom-Json
                    $usedStaleIndex = $true
                    return @{ index = $staleData; stale = $true }
                } catch {
                    Write-Warning "[lock_timeout_fallback] reason=lock_timeout, fallback=full_scan"
                    return @{ index = $null; stale = $true }
                }
            } else {
                Write-Warning "[lock_timeout_fallback] reason=lock_timeout, fallback=full_scan"
                return @{ index = $null; stale = $true }
            }
        }
        throw
    }

    try {
        # インデックス読み込み
        $index = $null
        $needFullRebuild = $Force

        if (-not $needFullRebuild -and (Test-Path $IdxPath)) {
            try {
                $raw = Get-Content (Assert-ScriptFileIoPath -Path ($IdxPath) -AllowWildcards) -Raw -Encoding utf8
                $index = $raw | ConvertFrom-Json
                if ($index.schemaVersion -ne $SCHEMA_VERSION) {
                    Write-Warning "[schema_version_mismatch] expected=$SCHEMA_VERSION actual=$($index.schemaVersion)"
                    $needFullRebuild = $true
                    $index = $null
                }
            } catch {
                Write-Warning "[index_corrupt] error=$_ → full rebuild"
                $needFullRebuild = $true
                $index = $null
            }
        }

        if (-not $index) { $needFullRebuild = $true }

        # 全件ハッシュ監査判定
        $needFullAudit = $false
        if (-not $needFullRebuild -and $index.lastFullAuditAt) {
            try {
                $lastAudit = [datetime]::Parse($index.lastFullAuditAt).ToUniversalTime()
                if (((Get-Date).ToUniversalTime() - $lastAudit).TotalHours -ge $FullAuditIntervalHours) {
                    $needFullAudit = $true
                }
            } catch {
                $needFullAudit = $true
            }
        } elseif (-not $needFullRebuild) {
            $needFullAudit = $true
        }

        # ファイルのキーマップ作成
        $fileMap = @{}
        foreach ($f in $AllFiles) {
            $relPath = $f.FullName.Substring($ResolvedRoot.Length + 1) -replace '\\', '/'
            $fileMap[$relPath] = $f
        }

        $entries = @{}
        if ($needFullRebuild) {
            # 全再構築
            foreach ($relPath in $fileMap.Keys) {
                $f = $fileMap[$relPath]
                $entries[$relPath] = Build-IndexEntry -File $f -ResolvedRoot $ResolvedRoot
            }
        } else {
            # 既存エントリを引き継ぐ
            $existingEntries = @{}
            if ($index.entries -is [PSCustomObject]) {
                foreach ($prop in $index.entries.PSObject.Properties) {
                    $existingEntries[$prop.Name] = $prop.Value
                }
            }

            # 削除されたファイル（index にあるが実ファイルなし）は $fileMap.Keys を走査する
            # 下記ループに含まれないため自然に除外される（旧 no-op 削除検知ループは撤去）。

            foreach ($relPath in $fileMap.Keys) {
                $f = $fileMap[$relPath]
                $existing = $null
                if ($existingEntries.ContainsKey($relPath)) {
                    $existing = $existingEntries[$relPath]
                }

                if ($existing) {
                    $fileMtime = $f.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
                    $fileSize = $f.Length

                    # mtime/size 一次フィルタ
                    $mtimeChanged = $existing.lastModified -ne $fileMtime
                    $sizeChanged = $existing.sizeBytes -ne $fileSize

                    # サイドカー変更検知
                    $sidecarChanged = $false
                    $sidecarPath = "$($f.FullName).meta.yaml"
                    if (Test-Path $sidecarPath) {
                        $sidecarMtime = (Get-Item $sidecarPath).LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
                        if ($existing.metadataLastModified -ne $sidecarMtime) {
                            $sidecarChanged = $true
                        }
                    } elseif ($existing.metadataLastModified) {
                        $sidecarChanged = $true
                    }

                    if ($mtimeChanged -or $sizeChanged -or $needFullAudit) {
                        # contentHash で最終判定
                        $needRebuild = $true
                        try {
                            $stream = [IO.File]::OpenRead((Assert-ScriptFileIoPath -Path ($f.FullName)))
                            try {
                                $sha = [Security.Cryptography.SHA256]::Create()
                                $hashBytes = $sha.ComputeHash($stream)
                                $currentHash = "sha256:" + ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLower()
                                if ($currentHash -eq $existing.contentHash -and -not $sidecarChanged) {
                                    $needRebuild = $false
                                    # mtime は変わったがハッシュは同じ → mtime だけ更新
                                    $entryCopy = @{}
                                    foreach ($prop in $existing.PSObject.Properties) {
                                        $entryCopy[$prop.Name] = $prop.Value
                                    }
                                    $entryCopy['lastModified'] = $fileMtime
                                    $entryCopy['sizeBytes'] = $fileSize
                                    $entries[$relPath] = $entryCopy
                                }
                            } finally { $stream.Close() }
                        } catch {
                            Write-Warning "[hash_compute_failed] path=$relPath error=$_"
                            $needRebuild = $true
                        }

                        if ($needRebuild) {
                            $entries[$relPath] = Build-IndexEntry -File $f -ResolvedRoot $ResolvedRoot
                        }
                    } elseif ($sidecarChanged) {
                        # サイドカーのみ変更 → summary だけ更新
                        $entryCopy = @{}
                        foreach ($prop in $existing.PSObject.Properties) {
                            $entryCopy[$prop.Name] = $prop.Value
                        }
                        $sidecarResult = Read-Sidecar -File $f -ResolvedRoot $ResolvedRoot
                        if ($sidecarResult.summary) {
                            $entryCopy['summary'] = $sidecarResult.summary
                            $entryCopy['metadataLastModified'] = $sidecarResult.lastModified
                        }
                        $entries[$relPath] = $entryCopy
                    } else {
                        # 変更なし → そのまま引き継ぐ
                        $entryCopy = @{}
                        foreach ($prop in $existing.PSObject.Properties) {
                            $entryCopy[$prop.Name] = $prop.Value
                        }
                        $entries[$relPath] = $entryCopy
                    }
                } else {
                    # 新規ファイル
                    $entries[$relPath] = Build-IndexEntry -File $f -ResolvedRoot $ResolvedRoot
                }
            }
        }

        # corpusStats: IDF テーブル + 平均トークン数を構築（BM25 用）
        $totalTokenCount = 0
        $docCount = $entries.Count
        $dfTable = @{}  # document frequency: 各キーワードが何文書に出現するか
        foreach ($relPath in $entries.Keys) {
            $e = $entries[$relPath]
            $tc = if ($e.tokenCount) { [int]$e.tokenCount } else { 0 }
            $totalTokenCount += $tc
            $seenTerms = @{}
            if ($e.keywords) {
                foreach ($kw in $e.keywords) {
                    if (-not $seenTerms.ContainsKey($kw)) {
                        $seenTerms[$kw] = $true
                        if ($dfTable.ContainsKey($kw)) { $dfTable[$kw]++ } else { $dfTable[$kw] = 1 }
                    }
                }
            }
        }
        $avgTokenCount = if ($docCount -gt 0) { $totalTokenCount / $docCount } else { 0 }
        # IDF 計算: log((N - df(t) + 0.5) / (df(t) + 0.5) + 1)
        $idfTable = @{}
        foreach ($term in $dfTable.Keys) {
            $df = $dfTable[$term]
            $idfTable[$term] = [Math]::Log(($docCount - $df + 0.5) / ($df + 0.5) + 1)
        }
        $corpusStats = @{
            totalDocs     = $docCount
            avgTokenCount = [Math]::Round($avgTokenCount, 2)
            idf           = $idfTable
        }

        $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $newIndex = @{
            schemaVersion   = $SCHEMA_VERSION
            updatedAt       = $now
            lastFullAuditAt = if ($needFullRebuild -or $needFullAudit) { $now } else { $index.lastFullAuditAt }
            entries         = $entries
            corpusStats     = $corpusStats
        }

        # Atomic 書き出し
        $pid_ = $PID
        $guid = [Guid]::NewGuid().ToString("N").Substring(0, 8)
        $tmpPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($IdxPath), ".search-index.tmp.$pid_.$guid.json")

        try {
            $newIndex | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path (Assert-ScriptFileIoPath -Path ($tmpPath) -AllowWildcards) -Encoding utf8 -NoNewline
            Move-Item -Path (Assert-ScriptFileIoPath -Path ($tmpPath) -AllowWildcards -Recurse) -Destination (Assert-ScriptFileIoPath -Path ($IdxPath)) -Force
        } catch {
            Write-Warning "[index_write_failed] error=$_"
            Remove-Item (Assert-ScriptFileIoPath -Path ($tmpPath) -AllowWildcards) -Force -ErrorAction SilentlyContinue
        }

        return @{ index = $newIndex; stale = $false }
    } finally {
        if ($lockStream) {
            $lockStream.Close()
            $lockStream.Dispose()
            Remove-Item (Assert-ScriptFileIoPath -Path ($lockPath) -AllowWildcards) -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── ソースルートの解決 ──
try {
    if ($SearchMode -eq 'FullText') {
        $SourceRoot = Resolve-ResearchSourceRoot -SourceRoot $SourceRoot -BaseRoot $repoRoot
    }
    if (-not (Test-Path $SourceRoot)) {
        Write-Output (New-Result -Status "empty" -ResolvedRoot $SourceRoot -Message "SourceRoot が存在しません: $SourceRoot")
        exit 0
    }
    $resolvedRoot = (Resolve-Path (Assert-ScriptFileIoPath -Path ($SourceRoot) -AllowWildcards)).Path
} catch {
    Write-Output (New-Result -Status "error" -ResolvedRoot $SourceRoot -Message 'source_root_unavailable')
    exit 1
}

try {
    $script:SourcePreferenceGroups = @(Read-SourcePreferenceGroups -Root $resolvedRoot)
} catch {
    Write-Output (New-Result -Status 'error' -ResolvedRoot $resolvedRoot -Message 'source_preference_invalid')
    exit 1
}

# Re-read even on a fresh index or historical search. Invalid records fail closed.
try {
    $script:CorpusCurrentness = Read-CorpusCurrentness -Root $resolvedRoot
} catch {
    Write-Output (New-Result -Status 'error' -ResolvedRoot $resolvedRoot -Message 'currentness_policy_invalid')
    exit 1
}

# ── 対象拡張子 ──
$allowedExtensions = @('.md', '.txt', '.json', '.csv', '.yaml', '.yml')

# ── インデックスパスの決定（ファイル列挙より前に行う: TTL 早期判定のため） ──
if ([string]::IsNullOrEmpty($IndexPath)) {
    $IndexPath = Resolve-DefaultIndexPath -RepoRoot $repoRoot -ResolvedRoot $resolvedRoot
}

# ── TTL 早期判定: fresh なら再帰列挙・per-file stat・再ハッシュをスキップ ──
# 注意: Get-ChildItem -Recurse より前に判定する。fresh のとき列挙自体を実行しない。
$useFullScan = $false
$indexData = $null
$ttlFresh = $false
$unsupportedFileCount = 0
if ($SearchMode -eq 'Indexed' -and $IndexFreshnessTtlSeconds -gt 0 -and -not $ForceReindex.IsPresent -and (Test-Path $IndexPath)) {
    try {
        # updatedAt の生文字列を保持するため -AsHashtable を使う（ConvertFrom-Json の既定は
        # ISO8601 文字列を [datetime] へ自動変換し、ローカル時刻として再解釈されて TTL 判定がズレる）。
        $existingHt = Get-Content (Assert-ScriptFileIoPath -Path ($IndexPath) -AllowWildcards) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        # entries 欠落/空の index で fresh 判定すると Phase 1 が空振りし empty を返すレースがある。
        # entries が 1 件以上ある場合のみ fresh とみなし、それ以外は stale 扱いで再列挙へフォールバックする。
        $entryCount = if ($existingHt.entries -is [System.Collections.IDictionary]) { $existingHt.entries.Count } else { 0 }
        if ($existingHt.schemaVersion -eq $SCHEMA_VERSION -and $existingHt.updatedAt -and $entryCount -gt 0) {
            # updatedAt は UTC（末尾 Z 付き "yyyy-MM-ddTHH:mm:ssZ"）。AssumeUniversal で確実に UTC 解釈する。
            $updatedAtUtc = [datetimeoffset]::Parse(
                [string]$existingHt.updatedAt, [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            ).UtcDateTime
            $ageSec = ((Get-Date).ToUniversalTime() - $updatedAtUtc).TotalSeconds
            if ($ageSec -ge 0 -and $ageSec -lt $IndexFreshnessTtlSeconds) {
                $ttlFresh = $true
                # 検索フローは PSCustomObject 前提のため、確定後に通常パースし直す。
                $indexData = Get-Content (Assert-ScriptFileIoPath -Path ($IndexPath) -AllowWildcards) -Raw -Encoding utf8 | ConvertFrom-Json
            }
        }
    } catch {
        $ttlFresh = $false
    }
}

if ($ttlFresh) {
    # 既存 index をそのまま使う（G: への再帰列挙・per-file stat・再ハッシュ・書込を全てスキップ）。
    # Phase 2 のスニペット用本文読込（G: I/O）は従来どおり残る。
    $scannedCount = @($indexData.entries.PSObject.Properties).Count
} else {
    # ── ファイル一覧の収集（生成物を除外） ──
    $excludedPatterns = Get-ExcludedPatterns
    $allFiles = @()
    try {
        $allEnumeratedFiles = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -ErrorAction Stop)
        $unsupportedFileCount = @($allEnumeratedFiles | Where-Object { $_.Extension -notin $allowedExtensions }).Count
        $allFiles = @($allEnumeratedFiles | Where-Object {
            $file = $_
            if ($file.Extension -notin $allowedExtensions) { return $false }
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            # ファイル名除外
            foreach ($pattern in $excludedPatterns.FileNames) {
                if ($file.Name -like $pattern) { return $false }
            }
            # グロブ除外
            foreach ($glob in $excludedPatterns.FileGlobs) {
                if ($file.Name -like $glob) { return $false }
            }
            # 隠しディレクトリ除外
            $relativePath = $file.FullName.Substring($resolvedRoot.Length + 1)
            foreach ($dirPattern in $excludedPatterns.DirPatterns) {
                $parts = $relativePath -split '[/\\]'
                foreach ($part in $parts[0..($parts.Length - 2)]) {
                    if ($part -match $dirPattern) { return $false }
                }
            }
            return $true
        })
    } catch {
        Write-Output (New-Result -Status "error" -ResolvedRoot $resolvedRoot -Message "ファイル走査エラー: $_")
        exit 1
    }

    $scannedCount = $allFiles.Count

    if ($scannedCount -eq 0) {
        Write-Output (New-Result -Status "empty" -ResolvedRoot $resolvedRoot -ScannedCount 0 -Message "対象ファイルが見つかりませんでした。" -UnsupportedFileCount $unsupportedFileCount)
        exit 0
    }

    # FullText は候補選別・TTL・インデックス更新を使わず、開始時に列挙した全対象を走査する。
    if ($SearchMode -eq 'FullText') {
        $rawKeywords = @(
            $Query -split '\s+' |
            Where-Object { $_.Length -gt 0 } |
            ForEach-Object { $_.ToLowerInvariant() }
        )
        if (@($rawKeywords).Count -eq 0) {
            Write-Output (New-Result -Status "error" -ResolvedRoot $resolvedRoot -ScannedCount $scannedCount -Message "クエリが空です。" -Mode $SearchMode)
            exit 1
        }
        # FullTextでは候補選別のためのサブワード分解を使わず、指定語をそのまま全件へ適用する。
        $fullTextKeywords = @($rawKeywords)
        if (@($SynonymKeywords).Count -gt 0) {
            foreach ($synonym in $SynonymKeywords) {
                $synLower = $synonym.ToLowerInvariant()
                if ($synLower -notin $fullTextKeywords) { $fullTextKeywords += $synLower }
            }
        }
        Write-Output (Invoke-FullTextSearch -Files $allFiles -ResolvedRoot $resolvedRoot -Keywords $fullTextKeywords `
            -Limit $MaxFiles -Start $Offset -SnippetLimit $MaxCharsPerFile -Mode $SearchMode `
            -UnsupportedFileCount $unsupportedFileCount)
        exit 0
    }

    # ── インデックス更新 ──
    $indexResult = Update-SearchIndex -ResolvedRoot $resolvedRoot -AllFiles $allFiles -IdxPath $IndexPath -Force $ForceReindex.IsPresent

    # ロックタイムアウトでインデックスも取得できなかった場合 → 全件走査フォールバック
    if ($indexResult.index) {
        $indexData = $indexResult.index
    } else {
        $useFullScan = $true
        Write-Warning "[lock_timeout_fallback] reason=no_index, fallback=full_scan"
    }
}

# ── サブワード分解 ──
function Split-Subwords {
    param([string[]]$Keywords)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($kw in $Keywords) {
        $result.Add($kw)
        if ($kw.Length -ge 3 -and $kw -match '[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}]') {
            $parts = [regex]::Split($kw, '(?<=[\p{IsKatakana}ー])(?=[\p{IsCJKUnifiedIdeographs}\p{IsHiragana}])|(?<=[\p{IsCJKUnifiedIdeographs}])(?=[\p{IsKatakana}])')
            if (@($parts).Count -gt 1) {
                foreach ($p in $parts) {
                    if ($p.Length -ge 2 -and -not $result.Contains($p)) {
                        $result.Add($p)
                    }
                }
            }
            $auxParts = [regex]::Split($kw, '(?<=[^\p{IsHiragana}])(?:の|と|及び|又は|等)(?=[^\p{IsHiragana}])')
            if (@($auxParts).Count -gt 1) {
                foreach ($p in $auxParts) {
                    if ($p.Length -ge 2 -and -not $result.Contains($p)) {
                        $result.Add($p)
                    }
                }
            }
        }
    }
    return @($result.ToArray())
}

# ── クエリ語の分割 ──
$rawKeywords = @(
    $Query -split '\s+' |
    Where-Object { $_.Length -gt 0 } |
    ForEach-Object { $_.ToLower() }
)
$rawKeywords = @($rawKeywords)

if (@($rawKeywords).Count -eq 0) {
    Write-Output (New-Result -Status "error" -ResolvedRoot $resolvedRoot -ScannedCount $scannedCount -Message "クエリが空です。")
    exit 1
}

$keywords = @(Split-Subwords -Keywords $rawKeywords)

# 同義語キーワードを追加（サブワード相当の低ウェイト扱い）
if (@($SynonymKeywords).Count -gt 0) {
    foreach ($syn in $SynonymKeywords) {
        $synLower = $syn.ToLower()
        if ($synLower -notin $keywords -and $synLower -notin $rawKeywords) {
            $keywords += $synLower
        }
    }
}

# ── 検索フロー ──
if ($useFullScan) {
    # フォールバック: 従来の全文スキャン
    $scored = @()
    foreach ($file in $allFiles) {
        try {
            $content = Get-Content (Assert-ScriptFileIoPath -Path ($file.FullName) -AllowWildcards) -Raw -Encoding utf8 -ErrorAction SilentlyContinue
            if ([string]::IsNullOrEmpty($content)) { continue }

            $contentLower = $content.ToLower()
            $fileNameLower = $file.Name.ToLower()
            $relativePath = $file.FullName.Substring($resolvedRoot.Length + 1) -replace '\\', '/'
            $dirSegments = ($relativePath -split '/')[0..([Math]::Max(0, ($relativePath -split '/').Count - 2))]
            $dirNameLower = ($dirSegments -join ' ').ToLower()

                $score = 0
                $keywordCount = @($keywords).Count
                for ($i = 0; $i -lt $keywordCount; $i++) {
                $kw = $keywords[$i]
                $isSubword = $kw -notin $rawKeywords
                if ($fileNameLower.Contains($kw)) {
                    $score += if ($isSubword) { $ScoreWeights.FileNameSub } else { $ScoreWeights.FileNameExact }
                }
                if ($dirNameLower.Contains($kw)) {
                    $score += if ($isSubword) { $ScoreWeights.DirSub } else { $ScoreWeights.DirExact }
                }
                $occurrences = ([regex]::Matches($contentLower, [regex]::Escape($kw))).Count
                $cap = if ($isSubword) { $ScoreWeights.KeywordFreqSubCap } else { $ScoreWeights.KeywordFreqCap }
                $score += [Math]::Min($occurrences, $cap)
            }

            if ($score -gt 0) {
                $snippet = ""
                $snippetCharStart = 0
                $snippetCharEnd = 0
                foreach ($kw in $keywords) {
                    $idx = $contentLower.IndexOf($kw)
                    if ($idx -ge 0) {
                        $start = [Math]::Max(0, $idx - 100)
                        $end = [Math]::Min($content.Length, $idx + $kw.Length + 200)
                        $snippet = $content.Substring($start, $end - $start).Trim()
                        $snippetCharStart = $start
                        $snippetCharEnd = $end
                        if ($snippet.Length -gt $MaxCharsPerFile) {
                            $snippet = $snippet.Substring(0, $MaxCharsPerFile)
                            $snippetCharEnd = $snippetCharStart + $MaxCharsPerFile
                        }
                        break
                    }
                }
                if ([string]::IsNullOrEmpty($snippet)) {
                    $snippet = $content.Substring(0, [Math]::Min($content.Length, $MaxCharsPerFile)).Trim()
                    $snippetCharStart = 0
                    $snippetCharEnd = [Math]::Min($content.Length, $MaxCharsPerFile)
                }
                $lineRange = Get-SnippetLineRange -Content $content -CharStart $snippetCharStart -CharEnd $snippetCharEnd
                $scored += @{
                    path             = $relativePath
                    score            = $score
                    snippet          = $snippet
                    snippetStartLine = $lineRange.start
                    snippetEndLine   = $lineRange.end
                    modifiedAt       = $file.LastWriteTimeUtc.ToString("o")
                }
            }
        } catch { continue }
    }
    if ($scored.Count -eq 0) {
        Write-Output (New-Result -Status "empty" -ResolvedRoot $resolvedRoot -ScannedCount $scannedCount -Message "クエリに一致するファイルが見つかりませんでした。")
        exit 0
    }
    $orderedMatches = @(Get-SourcePreferenceOrder -Matches @($scored | Sort-Object { $_.score } -Descending))
    $topMatches = $orderedMatches | Select-Object -First $MaxFiles
    Write-Output (New-Result -Status "ok" -ResolvedRoot $resolvedRoot -MatchList $topMatches -ScannedCount $scannedCount -Message "")
    exit 0
}

# ── Phase 1 スコアリング: インデックスのみ ──
$entries = @{}
if ($indexData.entries -is [PSCustomObject]) {
    foreach ($prop in $indexData.entries.PSObject.Properties) {
        $entries[$prop.Name] = $prop.Value
    }
} elseif ($indexData.entries -is [hashtable]) {
    $entries = $indexData.entries
}

# corpusStats の読み込み（BM25 パラメータ）
$corpusIdf = @{}
$avgDl = 0.0
$totalDocs = $entries.Count
if ($indexData.corpusStats) {
    $cs = $indexData.corpusStats
    $avgDl = if ($cs.avgTokenCount) { [double]$cs.avgTokenCount } else { 0.0 }
    if ($cs.idf -is [PSCustomObject]) {
        foreach ($prop in $cs.idf.PSObject.Properties) {
            $corpusIdf[$prop.Name] = [double]$prop.Value
        }
    } elseif ($cs.idf -is [hashtable]) {
        foreach ($key in $cs.idf.Keys) {
            $corpusIdf[$key] = [double]$cs.idf[$key]
        }
    }
}
$k1 = [double]$ScoreWeights.BM25_k1
$bm25b = [double]$ScoreWeights.BM25_b

$phase1Scores = @()
foreach ($relPath in $entries.Keys) {
    $entry = $entries[$relPath]
    $score = 0.0

    # 文書長（BM25 正規化用）
    $docLen = if ($entry.tokenCount) { [double]$entry.tokenCount } else { 0.0 }

    foreach ($kw in $keywords) {
        $isSubword = $kw -notin $rawKeywords

        # ファイル名マッチ（ボーナス）
        $fnNorm = if ($entry.fileNameNormalized) { $entry.fileNameNormalized } else { "" }
        if ($fnNorm.Contains($kw)) {
            $score += if ($isSubword) { $ScoreWeights.FileNameSub } else { $ScoreWeights.FileNameExact }
        }

        # ディレクトリマッチ（ボーナス）
        $dirSegs = @()
        if ($entry.dirSegments) {
            $dirSegs = @($entry.dirSegments)
        }
        $dirStr = ($dirSegs -join ' ').ToLower()
        if ($dirStr.Contains($kw)) {
            $score += if ($isSubword) { $ScoreWeights.DirSub } else { $ScoreWeights.DirExact }
        }

        # summary マッチ（ボーナス）
        $summaryLower = if ($entry.summary) { $entry.summary.ToLower() } else { "" }
        if ($summaryLower -and $summaryLower.Contains($kw)) {
            $score += if ($isSubword) { $ScoreWeights.SummarySub } else { $ScoreWeights.SummaryExact }
        }

        # keywordFreq 参照（完全一致 + 部分一致: クエリ語がキーに含まれる or キーがクエリ語に含まれる）
        # BM25 スコアリング: keywordFreq から tf を取得し BM25 公式を適用
        $tf = 0
        if ($entry.keywordFreq -is [PSCustomObject]) {
            foreach ($prop in $entry.keywordFreq.PSObject.Properties) {
                if ($prop.Name.Contains($kw) -or $kw.Contains($prop.Name)) {
                    $tf += [int]$prop.Value
                }
            }
        } elseif ($entry.keywordFreq -is [hashtable]) {
            foreach ($key in $entry.keywordFreq.Keys) {
                if ($key.Contains($kw) -or $kw.Contains($key)) {
                    $tf += [int]$entry.keywordFreq[$key]
                }
            }
        }

        if ($tf -gt 0) {
            $idf = if ($corpusIdf.ContainsKey($kw)) { $corpusIdf[$kw] } else { [Math]::Log($totalDocs + 1) }
            $denominator = $tf + $k1 * (1 - $bm25b + $bm25b * ($docLen / [Math]::Max($avgDl, 1)))
            $bm25Score = $idf * (($tf * ($k1 + 1)) / [Math]::Max($denominator, 0.001))
            $score += $bm25Score
        }
    }

    if ($score -gt 0) {
        $phase1Scores += @{
            relPath = $relPath
            score   = $score
        }
    }
}

# A user-pinned document must not disappear because its exact query term is
# outside the index's top-frequency keywords. Never inject an unmatched file.
if (-not $IgnoreSourcePreference) {
    foreach ($group in $script:SourcePreferenceGroups) {
        foreach ($entry in $group.documents) {
            if ($entry.role -eq 'preferred' -and $entry.rawMatchCount -gt 0 -and $entries.ContainsKey($entry.path) -and $entry.path -notin @($phase1Scores | ForEach-Object relPath)) {
                $phase1Scores += @{ relPath = $entry.path; score = [double]$entry.rawMatchCount }
            }
        }
    }
}

if ($phase1Scores.Count -eq 0) {
    Write-Output (New-Result -Status "empty" -ResolvedRoot $resolvedRoot -ScannedCount $scannedCount -Message "クエリに一致するファイルが見つかりませんでした。")
    exit 0
}

# ── Phase 2: top-K rerank (BM25 全文) + 近接度スニペット ──
$rerankTopK = [int]$(if ($env:CC_LWR_RERANK_TOP_K) { $env:CC_LWR_RERANK_TOP_K } else { 20 })
$rerankMaxTokens = [int]$(if ($env:CC_LWR_RERANK_MAX_TOKENS) { $env:CC_LWR_RERANK_MAX_TOKENS } else { 50000 })
$snippetTopN = [int]$(if ($env:CC_LWR_SNIPPET_TOP_N) { $env:CC_LWR_SNIPPET_TOP_N } else { 10 })
$snippetMaxChars = [int]$(if ($env:CC_LWR_SNIPPET_MAX_CHARS) { $env:CC_LWR_SNIPPET_MAX_CHARS } else { 100000 })

# Phase 1 上位候補を選出（rerank 対象 + 確定分）
$sortedPhase1 = @(Get-SourcePreferenceOrder -Matches @($phase1Scores | Sort-Object { $_.score } -Descending) -PathProperty 'relPath')
$rerankCandidates = $sortedPhase1 | Select-Object -First $rerankTopK
$nonRerankCandidates = $sortedPhase1 | Select-Object -Skip $rerankTopK | Select-Object -First ($MaxFiles * 2)

# rerank: 上位 K 件のみ全文読み込みで BM25 スコアを再計算
$scored = @()
foreach ($candidate in $rerankCandidates) {
    $relPath = $candidate.relPath
    $fullPath = Join-Path $resolvedRoot ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar.ToString())

    if (-not (Test-Path $fullPath)) { continue }

    try {
        $content = Get-Content (Assert-ScriptFileIoPath -Path ($fullPath) -AllowWildcards) -Raw -Encoding utf8 -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($content)) { continue }

        $contentLower = $content.ToLower()
        $fileInfo = Get-Item $fullPath
        $entry = $entries[$relPath]
        if (-not (Test-IndexedCandidateMatch -Entry $entry -ContentLower $contentLower -Keywords $keywords)) { continue }

        # tokenCount が rerank 上限を超える場合は Phase 1 スコアで確定（打ち切り）
        $docTokens = if ($entry.tokenCount) { [int]$entry.tokenCount } else { $content.Length }
        if ($docTokens -gt $rerankMaxTokens) {
            $scored += @{
                path             = $relPath
                score            = $candidate.score
                snippet          = ""
                snippetStartLine = 1
                snippetEndLine   = 1
                modifiedAt       = $fileInfo.LastWriteTimeUtc.ToString("o")
                needSnippet      = $true
            }
            continue
        }

        # 全文 BM25 rerank: 正確な tf で再計算
        $rerankScore = 0.0
        # ボーナスは Phase 1 から引き継ぐ（ファイル名/ディレクトリ/summary）
        $fnNorm = if ($entry.fileNameNormalized) { $entry.fileNameNormalized } else { "" }
        $dirSegs = @(); if ($entry.dirSegments) { $dirSegs = @($entry.dirSegments) }
        $dirStr = ($dirSegs -join ' ').ToLower()
        $summaryLower = if ($entry.summary) { $entry.summary.ToLower() } else { "" }
        # WI-2: 文書長は index の tokenCount を使用（avgDl=avgTokenCount と単位統一）。
        # 旧実装は文字数($content.Length)で avgDl(トークン数)と単位不一致だった。欠落時のみ文字数で代替。
        $docLenFull = if ($entry.tokenCount) { [double]$entry.tokenCount } else { [double]$content.Length }

        foreach ($kw in $keywords) {
            $isSubword = $kw -notin $rawKeywords
            if ($fnNorm.Contains($kw)) {
                $rerankScore += if ($isSubword) { $ScoreWeights.FileNameSub } else { $ScoreWeights.FileNameExact }
            }
            if ($dirStr.Contains($kw)) {
                $rerankScore += if ($isSubword) { $ScoreWeights.DirSub } else { $ScoreWeights.DirExact }
            }
            if ($summaryLower -and $summaryLower.Contains($kw)) {
                $rerankScore += if ($isSubword) { $ScoreWeights.SummarySub } else { $ScoreWeights.SummaryExact }
            }
            # 全文から正確な tf を算出
            $fullTf = ([regex]::Matches($contentLower, [regex]::Escape($kw))).Count
            if ($fullTf -gt 0) {
                $idf = if ($corpusIdf.ContainsKey($kw)) { $corpusIdf[$kw] } else { [Math]::Log($totalDocs + 1) }
                $denom = $fullTf + $k1 * (1 - $bm25b + $bm25b * ($docLenFull / [Math]::Max($avgDl, 1)))
                $rerankScore += $idf * (($fullTf * ($k1 + 1)) / [Math]::Max($denom, 0.001))
            }
        }

        $scored += @{
            path             = $relPath
            score            = $rerankScore
            snippet          = ""
            snippetStartLine = 1
            snippetEndLine   = 1
            modifiedAt       = $fileInfo.LastWriteTimeUtc.ToString("o")
            needSnippet      = $true
            content          = $content
            contentLower     = $contentLower
        }
    } catch { continue }
}

# rerank 対象外の候補も Phase 1 スコアで追加
foreach ($candidate in $nonRerankCandidates) {
    $relPath = $candidate.relPath
    $fullPath = Join-Path $resolvedRoot ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar.ToString())
    if (-not (Test-Path $fullPath)) { continue }
    try {
        $content = Get-Content -LiteralPath (Assert-ScriptFileIoPath -Path ($fullPath)) -Raw -Encoding utf8 -ErrorAction Stop
        if ([string]::IsNullOrEmpty($content)) { continue }
        if (-not (Test-IndexedCandidateMatch -Entry $entries[$relPath] -ContentLower $content.ToLower() -Keywords $keywords)) { continue }
        $fileInfo = Get-Item $fullPath
        $scored += @{
            path             = $relPath
            score            = $candidate.score
            snippet          = ""
            snippetStartLine = 1
            snippetEndLine   = 1
            modifiedAt       = $fileInfo.LastWriteTimeUtc.ToString("o")
            needSnippet      = $true
        }
    } catch { continue }
}

if ($scored.Count -eq 0) {
    Write-Output (New-Result -Status "empty" -ResolvedRoot $resolvedRoot -ScannedCount $scannedCount -Message "クエリに一致するファイルが見つかりませんでした。")
    exit 0
}

# ── 最終ソート → 上位 MaxFiles 件 ──
$orderedMatches = @(Get-SourcePreferenceOrder -Matches @($scored | Sort-Object { $_.score } -Descending))
$topMatches = @($orderedMatches | Select-Object -First $MaxFiles)

# ── 近接度スニペット抽出: 最終上位候補のみ ──
$snippetSw = [System.Diagnostics.Stopwatch]::new()
for ($mi = 0; $mi -lt $topMatches.Count -and $mi -lt $snippetTopN; $mi++) {
    $m = $topMatches[$mi]
    if (-not $m.needSnippet) { continue }

    $snippetSw.Restart()

    # コンテンツ取得（rerank 時に保持していればそれを使う、なければ読み込み）
    $sContent = $null; $sContentLower = $null
    if ($m.ContainsKey('content') -and $m.content) {
        $sContent = $m.content; $sContentLower = $m.contentLower
    } else {
        $fp = Join-Path $resolvedRoot ($m.path -replace '/', [IO.Path]::DirectorySeparatorChar.ToString())
        if (Test-Path $fp) {
            $sContent = Get-Content (Assert-ScriptFileIoPath -Path ($fp) -AllowWildcards) -Raw -Encoding utf8 -ErrorAction SilentlyContinue
            if ($sContent) { $sContentLower = $sContent.ToLower() }
        }
    }
    if (-not $sContent) {
        $m.snippet = ""
        $m.snippetStartLine = 1
        $m.snippetEndLine = 1
        continue
    }

    # 文書長上限チェック
    $processContent = $sContent
    $processLower = $sContentLower
    if ($processContent.Length -gt $snippetMaxChars) {
        $processContent = $processContent.Substring(0, $snippetMaxChars)
        $processLower = $processLower.Substring(0, $snippetMaxChars)
    }

    # キーワードが1つのみの場合は従来ロジック（回帰なし）
    if (@($keywords).Count -le 1) {
        $kw = $keywords[0]
        $idx = $processLower.IndexOf($kw)
        if ($idx -ge 0) {
            $start = [Math]::Max(0, $idx - 100)
            $end = [Math]::Min($processContent.Length, $idx + $kw.Length + 200)
            $m.snippet = $processContent.Substring($start, $end - $start).Trim()
            $snippetCharStart = $start
            $snippetCharEnd = $end
        } else {
            $m.snippet = $processContent.Substring(0, [Math]::Min($processContent.Length, $MaxCharsPerFile)).Trim()
            $snippetCharStart = 0
            $snippetCharEnd = [Math]::Min($processContent.Length, $MaxCharsPerFile)
        }
        if ($m.snippet.Length -gt $MaxCharsPerFile) {
            $m.snippet = $m.snippet.Substring(0, $MaxCharsPerFile)
            $snippetCharEnd = $snippetCharStart + $MaxCharsPerFile
        }
        $lineRange = Get-SnippetLineRange -Content $sContent -CharStart $snippetCharStart -CharEnd $snippetCharEnd
        $m.snippetStartLine = $lineRange.start
        $m.snippetEndLine = $lineRange.end
        continue
    }

    # 近接度スニペット: 全キーワードの出現位置を収集
    $positions = [System.Collections.Generic.List[int]]::new()
    $posKeyword = [System.Collections.Generic.List[string]]::new()
    foreach ($kw in $keywords) {
        $kwMatches = [regex]::Matches($processLower, [regex]::Escape($kw))
        foreach ($match in $kwMatches) {
            $positions.Add($match.Index)
            $posKeyword.Add($kw)
        }
    }

    if ($positions.Count -eq 0) {
        $m.snippet = $processContent.Substring(0, [Math]::Min($processContent.Length, $MaxCharsPerFile)).Trim()
        $lineRange = Get-SnippetLineRange -Content $sContent -CharStart 0 -CharEnd ([Math]::Min($processContent.Length, $MaxCharsPerFile))
        $m.snippetStartLine = $lineRange.start
        $m.snippetEndLine = $lineRange.end
        continue
    }

    # スライディングウィンドウで最適区間を選択
    $windowSize = 300
    $bestStart = $positions[0]
    $bestScore = 0

    # 位置をソートし、ウィンドウ内のユニークキーワード数 × 密度 を最大化
    # O(n^2) を避けるため、両端ポインタで線形に走査する
    $sortedIdx = @(0..($positions.Count - 1) | Sort-Object { $positions[$_] })
    $sortedPos = [System.Collections.Generic.List[int]]::new()
    $sortedKw = [System.Collections.Generic.List[string]]::new()
    foreach ($idx in $sortedIdx) {
        $sortedPos.Add($positions[$idx])
        $sortedKw.Add($posKeyword[$idx])
    }

    $right = 0
    $kwFreq = @{}
    $windowCount = 0

    for ($si = 0; $si -lt $sortedPos.Count; $si++) {
        $wStart = $sortedPos[$si]
        $wEnd = $wStart + $windowSize

        while ($right -lt $sortedPos.Count -and $sortedPos[$right] -le $wEnd) {
            $kw = $sortedKw[$right]
            if ($kwFreq.ContainsKey($kw)) { $kwFreq[$kw]++ } else { $kwFreq[$kw] = 1 }
            $windowCount++
            $right++
        }

        $uniqueCount = $kwFreq.Count
        $wScore = $uniqueCount * $uniqueCount * $windowCount  # ユニーク数^2 × 密度
        if ($wScore -gt $bestScore) {
            $bestScore = $wScore
            $bestStart = $wStart
        }

        $leftKw = $sortedKw[$si]
        if ($kwFreq.ContainsKey($leftKw)) {
            $kwFreq[$leftKw]--
            if ($kwFreq[$leftKw] -le 0) { $kwFreq.Remove($leftKw) }
            if ($windowCount -gt 0) { $windowCount-- }
        }

        # 処理時間チェック（500ms 打ち切り）
        if ($snippetSw.ElapsedMilliseconds -gt 500) { break }
    }

    $sStart = [Math]::Max(0, $bestStart - 50)
    $sEnd = [Math]::Min($processContent.Length, $bestStart + $windowSize + 50)
    $m.snippet = $processContent.Substring($sStart, $sEnd - $sStart).Trim()
    if ($m.snippet.Length -gt $MaxCharsPerFile) {
        $m.snippet = $m.snippet.Substring(0, $MaxCharsPerFile)
        $sEnd = $sStart + $MaxCharsPerFile
    }
    $lineRange = Get-SnippetLineRange -Content $sContent -CharStart $sStart -CharEnd $sEnd
    $m.snippetStartLine = $lineRange.start
    $m.snippetEndLine = $lineRange.end
}

# スニペットが未設定の残りエントリにフォールバック
foreach ($m in $topMatches) {
    if ([string]::IsNullOrEmpty($m.snippet)) {
        $fp = Join-Path $resolvedRoot ($m.path -replace '/', [IO.Path]::DirectorySeparatorChar.ToString())
        if (Test-Path $fp) {
            $fallbackContent = Get-Content (Assert-ScriptFileIoPath -Path ($fp) -AllowWildcards) -Raw -Encoding utf8 -ErrorAction SilentlyContinue
            if ($fallbackContent) {
                $fallbackEnd = [Math]::Min($fallbackContent.Length, $MaxCharsPerFile)
                $m.snippet = $fallbackContent.Substring(0, $fallbackEnd).Trim()
                $lineRange = Get-SnippetLineRange -Content $fallbackContent -CharStart 0 -CharEnd $fallbackEnd
                $m.snippetStartLine = $lineRange.start
                $m.snippetEndLine = $lineRange.end
            }
        }
    }
}

# 出力用にクリーンアップ（内部フィールドを除去）
$outputMatches = $topMatches | ForEach-Object {
    @{
        path             = $_.path
        score            = $_.score
        snippet          = $_.snippet
        snippetStartLine = $_.snippetStartLine
        snippetEndLine   = $_.snippetEndLine
        modifiedAt       = $_.modifiedAt
    }
}

Write-Output (New-Result -Status "ok" -ResolvedRoot $resolvedRoot -MatchList $outputMatches -ScannedCount $scannedCount -Message "")
