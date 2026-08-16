<#
.SYNOPSIS
    CacheDir が許可されたルート配下にあるかを検証する。
.DESCRIPTION
    許可rootは2つ: 現行既定の .cache/cc-local-web-research/web-cache（新）と、
    移行安全策として残す .claude/tmp/web-cache（旧、明示的な -CacheDir 指定時のみ
    到達可能で、いずれのscriptも既定値としては使わない）。
.PARAMETER CacheDir
    検証対象のキャッシュディレクトリパス。
.PARAMETER RepoRoot
    リポジトリルートパス。
.OUTPUTS
    [bool] いずれかの許可root配下なら $true、両方の境界外なら $false。
#>
param(
    [Parameter(Mandatory)][string]$CacheDir,
    [Parameter(Mandatory)][string]$RepoRoot
)

# GetFullPath: 相対パス / ".." を正規化（論理パス解決のみ。symlink/junction の実体先は解決しない）
$resolvedDir = [System.IO.Path]::GetFullPath($CacheDir)
$allowedRoots = @(
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot ".cache/cc-local-web-research/web-cache")),
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot ".claude/tmp/web-cache"))
)

$resolvedPrefix = $resolvedDir.TrimEnd(
    [IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$withinAnyAllowedRoot = $false
foreach ($allowedRoot in $allowedRoots) {
    $allowedPrefix = $allowedRoot.TrimEnd(
        [IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedPrefix.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedDir -eq $allowedRoot) {
        $withinAnyAllowedRoot = $true
        break
    }
}

if (-not $withinAnyAllowedRoot) {
    Write-Warning "[web_cache] boundary rejected: $resolvedDir (allowed: $($allowedRoots -join ', '))"
    return $false
}

# symlink / junction 追加ガード（.NET 6+ / PS 7.1+）
if (Test-Path $CacheDir) {
    $dirInfo = [System.IO.DirectoryInfo]::new($resolvedDir)
    # LinkTarget は .NET 6+ / PS 7.1+。PS 5.1 ではプロパティが存在しないためスキップ
    if ($dirInfo.PSObject.Properties.Name -contains 'LinkTarget' -and $dirInfo.LinkTarget) {
        Write-Warning "[web_cache] boundary rejected: $resolvedDir is a symlink/junction to $($dirInfo.LinkTarget)"
        return $false
    }
}

return $true
