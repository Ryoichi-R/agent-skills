<#
.SYNOPSIS
    Web cache関連script（Set-WebCache / Get-WebCache / Invoke-WebCacheCleanup）が
    共有する自己完結ヘルパー（文字列hashとTTL定数）。
.DESCRIPTION
    workspace専用の scripts/shared/hash-utils.ps1 や scripts/shared/web-cache-constants.ps1
    には依存しない。公開plugin配布時にも同梱されるSkill内蔵ヘルパーであり、Skill外への
    参照を持たない。
#>

Set-StrictMode -Version Latest

# クリーンアップ閾値（最大 TTL、秒）
$script:MAX_CACHE_TTL_SECONDS = 86400  # 24h

# intent 別 TTL (秒)
$script:IntentTTL = @{
    definition      = 86400   # 24h
    howto           = 14400   # 4h
    troubleshooting = 3600    # 1h
    factcheck       = 1800    # 30min
    comparison      = 7200    # 2h
    default         = 7200    # 2h
}

# negative cache TTL (秒)
$script:NegativeTTL = 300  # 5min

function Get-WebCacheStringHash {
    <#
    .SYNOPSIS
        文字列の SHA-256 ハッシュ（先頭 N 文字）を算出する。
    .DESCRIPTION
        改行コードを LF に正規化してから SHA-256 を算出し、先頭 $HashLength 文字を返す。
        キャッシュキー生成に使用する。
    .PARAMETER InputString
        ハッシュ対象の文字列。
    .PARAMETER HashLength
        返却するハッシュの文字数（既定: 8）。最大 64。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputString,
        [int]$HashLength = 8
    )
    $lfContent = $InputString -replace "`r`n", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($lfContent)
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hashBytes)).ToLowerInvariant().Substring(0, $HashLength)
}
