#Requires -Version 7.0
<#
.SYNOPSIS
    期限切れ Web キャッシュファイルを削除するクリーンアップスクリプト。
.DESCRIPTION
    24時間（MAX_CACHE_TTL_SECONDS）超過の .json キャッシュファイルを削除する。
    ベストエフォート設計: 個別ファイル削除失敗はスキップして続行。
    全ログは stderr に JSON Lines で出力する。
.PARAMETER CacheDir
    キャッシュディレクトリパス。省略時は <repoRoot>/.cache/cc-local-web-research/web-cache を自動解決。
#>

[CmdletBinding()]
param(
    [string]$CacheDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── ヘルパー関数 ──

function Write-CleanupLog([hashtable]$LogEntry) {
    $LogEntry['timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
    if (-not $LogEntry.ContainsKey('version')) { $LogEntry['version'] = 1 }
    [Console]::Error.WriteLine(($LogEntry | ConvertTo-Json -Compress))
}

function Resolve-EnvInt([string]$Name, [int]$Default, [int]$Min, [int]$Max) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if (-not $raw) { return $Default }
    $val = 0
    if (-not [int]::TryParse($raw, [ref]$val)) {
        Write-CleanupLog @{ event="web_cache_cleanup"; reason="env_parse_fallback"; detail="$Name='$raw' is not integer, using default=$Default" }
        return $Default
    }
    [Math]::Max($Min, [Math]::Min($Max, $val))
}

function Resolve-RepoRoot {
    # git repoならその toplevel、そうでなければ呼び出し時のカレントディレクトリを起点にする
    # （公開plugin配布先はSkillのインストール先と無関係な任意のディレクトリで実行され得るため、
    # Skillのインストール先パスからの相対計算は行わない）。
    $root = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $root) { return $root }
    return (Get-Location).Path
}

# ── 無効化チェック ──

$cleanupDisabled = ($env:CC_WEBCACHE_CLEANUP_DISABLED -and $env:CC_WEBCACHE_CLEANUP_DISABLED.Trim().ToLower() -eq "true")
if ($cleanupDisabled) {
    Write-CleanupLog @{ event="web_cache_cleanup"; reason="disabled"; deleted_count=0; failed_count=0; scanned_count=0; elapsed_ms=0; max_limit=0; truncated=$false }
    return
}

# ── repoRoot 解決 ──

$repoRoot = Resolve-RepoRoot
if (-not $repoRoot) {
    Write-CleanupLog @{ event="web_cache_cleanup"; reason="repo_root_failed"; deleted_count=0; failed_count=0; scanned_count=0; elapsed_ms=0; max_limit=0; truncated=$false }
    return
}

# CacheDir デフォルト解決
if (-not $CacheDir) {
    $CacheDir = Join-Path $repoRoot ".cache/cc-local-web-research/web-cache"
}

# ── TTL 定数読み込み（Skill内蔵の自己完結ヘルパー） ──

try {
    . "$PSScriptRoot/_web-cache-shared.ps1"
} catch {
    Write-CleanupLog @{ event="web_cache_cleanup"; reason="constants_load_failed"; detail="$_"; deleted_count=0; failed_count=0; scanned_count=0; elapsed_ms=0; max_limit=0; truncated=$false }
    return
}

# ── パス安全境界チェック ── (共通 helper)
$boundaryOk = & "$PSScriptRoot/Assert-WebCacheBoundary.ps1" `
    -CacheDir $CacheDir -RepoRoot $repoRoot
if (-not $boundaryOk) {
    Write-CleanupLog @{ event="web_cache_cleanup"; reason="boundary_rejected";
        detail="Refused: $CacheDir"; deleted_count=0; failed_count=0;
        scanned_count=0; elapsed_ms=0; max_limit=0; truncated=$false }
    return
}

# ── キャッシュディレクトリ存在チェック ──

if (-not (Test-Path $CacheDir)) {
    Write-CleanupLog @{ event="web_cache_cleanup"; reason="ttl_expired"; deleted_count=0; failed_count=0; scanned_count=0; elapsed_ms=0; max_limit=0; truncated=$false }
    return
}

# ── 環境変数解決 ──

$maxLimit = Resolve-EnvInt 'CC_WEBCACHE_CLEANUP_MAX' 50 1 200
$timeoutMs = Resolve-EnvInt 'CC_WEBCACHE_CLEANUP_TIMEOUT_MS' 10000 1000 60000

# ── クリーンアップ実行 ──

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$now = (Get-Date).ToUniversalTime()
$deletedCount = 0
$failedCount = 0
$truncated = $false
$failures = @()

# フラット構造前提のファイル列挙（再帰なし）
$candidates = Get-ChildItem -Path $CacheDir -Filter "*.json" -File -ErrorAction SilentlyContinue
$scannedCount = if ($candidates) { @($candidates).Count } else { 0 }

foreach ($file in $candidates) {
    # タイムアウトチェック
    if ($sw.ElapsedMilliseconds -ge $timeoutMs) {
        $truncated = $true
        Write-CleanupLog @{
            event="web_cache_cleanup"; reason="timeout"
            deleted_count=$deletedCount; failed_count=$failedCount; scanned_count=$scannedCount
            elapsed_ms=[int]$sw.ElapsedMilliseconds; max_limit=$maxLimit; truncated=$true
        }
        $sw.Stop()
        return
    }

    # 削除上限チェック
    if ($deletedCount -ge $maxLimit) {
        $truncated = $true
        break
    }

    # reparse point（junction/symlink）スキップ
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $failedCount++
        $failures += @{ file = $file.Name; error = "reparse_point_skipped" }
        continue
    }

    # TTL チェック（LastWriteTimeUtc ベース）
    $age = ($now - $file.LastWriteTimeUtc).TotalSeconds
    if ($age -le $script:MAX_CACHE_TTL_SECONDS) {
        continue
    }

    # 削除（個別 try/catch）
    try {
        Remove-Item -Path $file.FullName -Force
        $deletedCount++
    } catch {
        $failedCount++
        if ($failures.Count -lt 10) {
            $failures += @{ file = $file.Name; error = "$_" }
        }
    }
}

$sw.Stop()

# ── 結果ログ ──

$logEntry = @{
    event         = "web_cache_cleanup"
    reason        = "ttl_expired"
    deleted_count = $deletedCount
    failed_count  = $failedCount
    scanned_count = $scannedCount
    elapsed_ms    = [int]$sw.ElapsedMilliseconds
    max_limit     = $maxLimit
    truncated     = $truncated
}

if ($failures.Count -gt 0) {
    $logEntry['failures'] = $failures
    if ($failedCount -gt 10) {
        $logEntry['failures_truncated'] = $failedCount - 10
    }
}

Write-CleanupLog $logEntry
