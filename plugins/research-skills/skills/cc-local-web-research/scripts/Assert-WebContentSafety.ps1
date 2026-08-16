<#
.SYNOPSIS
    Web検索結果のサニタイズ検証を行う。

.DESCRIPTION
    SKILL.md Phase C「web_results サニタイズルール」の実装。
    以下の検証・変換を適用する:
    1. HTML/JavaScript タグ除去
    2. プロンプトインジェクション文字列除去
    3. snippet を最大 2000 文字に切り詰め
    4. URL スキームは https:// のみ許可
    5. results 配列は最大 10 件に制限

.PARAMETER WebResults
    Web検索結果オブジェクト（results 配列を含む PSCustomObject）。

.PARAMETER MaxSnippetLength
    snippet の最大文字数。デフォルト: 2000。

.PARAMETER MaxResults
    results 配列の最大件数。デフォルト: 10。

.OUTPUTS
    PSCustomObject: sanitized_results, rejected_entries, warnings
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$WebResults,

    [int]$MaxSnippetLength = 2000,
    [int]$MaxResults = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# プロンプトインジェクションパターン（大文字小文字無視）
$INJECTION_PATTERNS = @(
    'ignore\s+(previous|above|all)\s+(instructions?|prompts?)',
    'system\s*:',
    '<\|im_start\|>',
    '<\|im_end\|>',
    'you\s+are\s+(now|a)\s+',
    'pretend\s+(you|to)\s+',
    'forget\s+(everything|all|previous)',
    'new\s+instructions?\s*:',
    'override\s+(previous|system)',
    'disregard\s+(previous|above|all)',
    '\[INST\]',
    '\[/INST\]',
    '<<SYS>>',
    '<</SYS>>'
)
$injectionRegex = ($INJECTION_PATTERNS | ForEach-Object { "($_)" }) -join "|"

# 禁止 URL スキーム
$BLOCKED_SCHEMES = @('javascript:', 'data:', 'file:', 'vbscript:', 'blob:')

# HTML/Script タグ除去パターン
$HTML_TAG_PATTERNS = @(
    '<script[^>]*>[\s\S]*?</script>',
    '<style[^>]*>[\s\S]*?</style>',
    '<iframe[^>]*>[\s\S]*?</iframe>',
    '<object[^>]*>[\s\S]*?</object>',
    '<embed[^>]*/?>'
)
$htmlDangerousRegex = ($HTML_TAG_PATTERNS | ForEach-Object { "($_)" }) -join "|"
# 一般的な HTML タグ（コンテンツ保持、タグのみ除去）
$htmlGeneralRegex = '<[^>]+>'

function Remove-DangerousContent {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    # 1. 危険な HTML タグとその内容を除去
    $cleaned = [regex]::Replace($Text, $htmlDangerousRegex, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)

    # 2. 残りの HTML タグを除去（内容は保持）
    $cleaned = [regex]::Replace($cleaned, $htmlGeneralRegex, '')

    # 3. プロンプトインジェクションパターンを除去
    $cleaned = [regex]::Replace($cleaned, $injectionRegex, '[REMOVED]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    return $cleaned
}

function Test-UrlSafety {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

    foreach ($scheme in $BLOCKED_SCHEMES) {
        if ($Url.TrimStart().ToLower().StartsWith($scheme)) {
            return $false
        }
    }

    if (-not $Url.TrimStart().ToLower().StartsWith("https://")) {
        return $false
    }

    return $true
}

# --- Main ---

$sanitizedResults = @()
$rejectedEntries = @()
$warnings = @()

$results = $null
if ($null -ne $WebResults) {
    $resultsProp = $WebResults.PSObject.Properties['results']
    if ($null -ne $resultsProp) { $results = $resultsProp.Value }
}
if ($null -eq $results) {
    $results = @()
}
# original_count は null ガード済み・切り詰め前のローカル変数から算出する
# （$WebResults.results が null/不在のとき StrictMode 例外を起こさないため）
$originalCount = @($results).Count

# 5. 最大件数制限
if ($results.Count -gt $MaxResults) {
    $warnings += "[INFO] Results truncated from $($results.Count) to $MaxResults"
    $results = $results[0..($MaxResults - 1)]
}

foreach ($entry in $results) {
    $rejection = $null

    # 4. URL スキーム検証
    $url = $entry.url
    if (-not [string]::IsNullOrWhiteSpace($url)) {
        if (-not (Test-UrlSafety -Url $url)) {
            $rejection = "blocked_url_scheme"
            $rejectedEntries += [PSCustomObject]@{
                url    = $url
                reason = $rejection
            }
            $warnings += "[WARN] Rejected entry with blocked URL scheme: $url"
            continue
        }
    }

    # 1-3. コンテンツサニタイズ
    $sanitizedEntry = $entry.PSObject.Copy()

    if ($sanitizedEntry.PSObject.Properties.Name -contains "snippet") {
        $original = $sanitizedEntry.snippet
        $sanitizedEntry.snippet = Remove-DangerousContent -Text $original

        # 3. 文字数制限
        if ($sanitizedEntry.snippet.Length -gt $MaxSnippetLength) {
            $sanitizedEntry.snippet = $sanitizedEntry.snippet.Substring(0, $MaxSnippetLength)
            $warnings += "[INFO] Snippet truncated to $MaxSnippetLength chars for: $url"
        }
    }

    if ($sanitizedEntry.PSObject.Properties.Name -contains "title") {
        $sanitizedEntry.title = Remove-DangerousContent -Text $sanitizedEntry.title
    }

    $sanitizedResults += $sanitizedEntry
}

return [PSCustomObject]@{
    sanitized_results = $sanitizedResults
    rejected_entries  = $rejectedEntries
    warnings          = $warnings
    original_count    = $originalCount
    sanitized_count   = $sanitizedResults.Count
}
