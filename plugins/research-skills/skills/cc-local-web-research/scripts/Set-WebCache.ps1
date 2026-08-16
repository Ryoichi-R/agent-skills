#Requires -Version 7.0
<#
.SYNOPSIS
    Web検索結果をキャッシュに保存。原子的書き込み + negative cache 対応。
.PARAMETER Query
    検索クエリ文字列。
.PARAMETER Intent
    検索意図。
.PARAMETER MaxResults
    最大結果数。
.PARAMETER Locale
    ロケール。
.PARAMETER Data
    キャッシュするデータ（JSON 文字列）。pwsh -File 起動でのプロセス境界対応のため
    オブジェクトではなく JSON 文字列で受け取り、内部で ConvertFrom-Json する。
.PARAMETER IsNegative
    エラー/空結果の場合 $true を指定（短TTLで保存）。
.PARAMETER CacheDir
    キャッシュディレクトリパス。
.OUTPUTS
    stdout に単一行の status JSON を出力する（ベストエフォート設計のため exit は常に 0）:
    {"status":"ok","path":<cache_path>,"negative":bool} / {"status":"skipped","reason":...} / {"status":"error","message":...}
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Query,

    [string]$Intent = "default",

    [int]$MaxResults = 5,

    [string]$Locale = "ja",

    [Parameter(Mandatory)]
    [string]$Data,

    [switch]$IsNegative,

    [string]$CacheDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ── 結果は stdout に単一 status JSON で出力する（プロセス境界対応・ベストエフォート） ──
function Write-CacheStatus {
    param([Parameter(Mandatory)][hashtable]$Result)
    Write-Output ($Result | ConvertTo-Json -Compress)
}

# ── -Data（JSON 文字列）をオブジェクトへパース ──
try {
    $parsedData = $Data | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-CacheStatus @{ status = "error"; message = "invalid JSON in -Data: $_" }
    return
}

# ── キャッシュディレクトリ解決 ──
# git repoならその toplevel、そうでなければ呼び出し時のカレントディレクトリを起点にする
# （公開plugin配布先はSkillのインストール先と無関係な任意のディレクトリで実行され得るため、
# Skillのインストール先パスからの相対計算は行わない）。
$repoRoot = git rev-parse --show-toplevel 2>$null
if (-not $repoRoot) {
    $repoRoot = (Get-Location).Path
}
if ([string]::IsNullOrEmpty($CacheDir)) {
    $CacheDir = Join-Path $repoRoot ".cache/cc-local-web-research/web-cache"
}

# ── パス境界チェック ──
$boundaryOk = & "$PSScriptRoot/Assert-WebCacheBoundary.ps1" `
    -CacheDir $CacheDir -RepoRoot $repoRoot
if (-not $boundaryOk) {
    Write-CacheStatus @{ status = "skipped"; reason = "boundary_check_failed" }
    return
}

if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
}

# ── クエリ正規化 + ハッシュ（Get-WebCache と同一ロジック） ──
$normalizedQuery = ($Query.Trim().ToLower() -replace '\s+', ' ')
$cacheKeyInput = "$normalizedQuery|$Intent|$MaxResults|$Locale"
# _web-cache-shared.ps1 を dot-source（Skill内蔵の自己完結ヘルパー。pwsh -File 起動のため毎回1回のみ実行）
. "$PSScriptRoot/_web-cache-shared.ps1"
$cacheKey = Get-WebCacheStringHash -InputString $cacheKeyInput -HashLength 16

$cachePath = Join-Path $CacheDir "$cacheKey.json"

# ── キャッシュエントリ構築 ──
$entry = @{
    query      = $normalizedQuery
    intent     = $Intent
    max_results = $MaxResults
    locale     = $Locale
    cached_at  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    data       = $parsedData
}
if ($IsNegative.IsPresent) {
    $entry["_negative"] = $true
}

# ── 原子的書き込み（.tmp → fsync → リネーム） ──
$tmpPath = "$cachePath.tmp.$PID"
try {
    $entry | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $tmpPath -Encoding utf8 -NoNewline

    # fsync: ディスクへの永続化を保証（ベストエフォート）
    $fsyncDisabled = ($env:CC_WEBCACHE_FSYNC_DISABLED -and $env:CC_WEBCACHE_FSYNC_DISABLED.Trim().ToLower() -eq "true")
    if (-not $fsyncDisabled) {
        try {
            $fs = [System.IO.FileStream]::new($tmpPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            try {
                $fs.Flush($true)
            } finally {
                $fs.Dispose()
            }
        } catch {
            Write-Warning "[web_cache] fsync warning: $_ path=$tmpPath"
        }
    }

    Move-Item -Path $tmpPath -Destination $cachePath -Force
    Write-CacheStatus @{ status = "ok"; path = $cachePath; negative = [bool]$IsNegative.IsPresent }
} catch {
    Write-Warning "[web_cache] write error: $_ path=$cachePath"
    Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
    Write-CacheStatus @{ status = "error"; message = "$_" }
}
