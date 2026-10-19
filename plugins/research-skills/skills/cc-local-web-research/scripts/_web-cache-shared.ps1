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

# Portable copy of scripts/shared/secret-patterns.ps1 functions.
# FileIoPathGuard.Tests.ps1 enforces exact function parity with the canonical policy.
function Get-SecretFilePatterns {
    <#
    .SYNOPSIS
        秘密ファイルパターン（正規表現）の配列を返す
    #>
    return @(
        '^\.env$'
        '^\.env\.'
        '^secrets\.'
        '\.key$'
        '\.pem$'
        '\.pfx$'
        '\.p12$'
        '^credentials\.'
    )
}

function Test-SecretFilePath {
    <#
    .SYNOPSIS
        パスが秘密ファイルパターンに該当するか検査する
    .PARAMETER FilePath
        検査対象のファイルパス（絶対パスまたは相対パス）
    .OUTPUTS
        [bool] 秘密ファイルパターンに該当する場合は $true
    #>
    param([string]$FilePath)
    $leaf = Split-Path $FilePath -Leaf
    $patterns = Get-SecretFilePatterns
    foreach ($pat in $patterns) {
        if ($leaf -match $pat) {
            Write-Error "秘密ファイルパターンに該当するパスが検出されました: $FilePath"
            return $true
        }
    }
    return $false
}

function Assert-FileIoPathAllowed {
    <#
    .SYNOPSIS
        Validate actual I/O operands while preserving their original binding values.
    .DESCRIPTION
        The caller supplies the existing Test-SecretFilePath policy. Wildcards and
        recursive copy/move sources are expanded as metadata only, before any
        caller reads, copies or writes file content. No secret content is opened.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][AllowEmptyString()][object]$Path,
        [Parameter(Mandatory)][scriptblock]$SecretPathTest,
        [switch]$AllowWildcards,
        [switch]$Recurse
    )
    $ErrorActionPreference = 'Stop'
    foreach ($item in @($Path)) {
        if ($null -eq $item) { continue }
        $candidate = if ($item -is [IO.FileSystemInfo]) { $item.FullName } else { [string]$item }
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $normalized = [IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
        $ancestor = $normalized
        while (-not [string]::IsNullOrWhiteSpace($ancestor)) {
            if (& $SecretPathTest $ancestor) { throw 'SECRET_PATH_REJECTED' }
            $parent = [IO.Path]::GetDirectoryName($ancestor)
            if ($parent -eq $ancestor) { break }
            $ancestor = $parent
        }
        $resolved = @()
        if ($AllowWildcards -and [Management.Automation.WildcardPattern]::ContainsWildcardCharacters($candidate)) {
            $resolved = @(Resolve-Path -Path $candidate -ErrorAction SilentlyContinue | ForEach-Object ProviderPath)
            foreach ($resolvedPath in $resolved) {
                $null = Assert-FileIoPathAllowed -Path $resolvedPath -SecretPathTest $SecretPathTest
            }
        } else {
            $resolved = @($candidate)
        }
        if ($Recurse) {
            foreach ($source in $resolved) {
                if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
                foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
                    $null = Assert-FileIoPathAllowed -Path $file.FullName -SecretPathTest $SecretPathTest
                }
            }
        }
    }
    return ,$Path
}

function New-GuardedTempFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$SecretPathTest)
    $null = Assert-FileIoPathAllowed -Path ([IO.Path]::GetTempPath()) -SecretPathTest $SecretPathTest
    return [IO.Path]::GetTempFileName()
}
