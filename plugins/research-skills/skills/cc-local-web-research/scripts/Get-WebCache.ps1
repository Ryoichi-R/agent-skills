#Requires -Version 7.0
<#
.SYNOPSIS
    Web検索結果キャッシュの取得。intent別TTL + negative cache 対応。
.DESCRIPTION
    クエリを正規化・ハッシュ化し、キャッシュディレクトリから結果を検索する。
    TTL は intent に応じて異なり、negative cache（エラー/空結果）は短TTLで保持する。
.PARAMETER Query
    検索クエリ文字列。
.PARAMETER Intent
    検索意図。definition/howto/troubleshooting/factcheck/comparison/(default)。
.PARAMETER MaxResults
    最大結果数（キャッシュキーに含む）。
.PARAMETER Locale
    ロケール（キャッシュキーに含む）。
.PARAMETER CacheDir
    キャッシュディレクトリパス。
.OUTPUTS
    stdout に単一行の JSON を出力する（pwsh -File 起動でのプロセス境界対応）:
    キャッシュヒット時: {"hit":true,"data":<cached_data>,"negative":false|true,"age_seconds":<int>}
    キャッシュミス時:   {"hit":false}
    呼び出し側は `pwsh -NoProfile -File ... | ConvertFrom-Json` で受け取る。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Query,

    [string]$Intent = "default",

    [int]$MaxResults = 5,

    [string]$Locale = "ja",

    [string]$CacheDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ── 結果は stdout に単一 JSON で出力する（pwsh -File 起動でのプロセス境界対応） ──
function Write-CacheResult {
    param([Parameter(Mandatory)] $Result)
    Write-Output ($Result | ConvertTo-Json -Depth 12 -Compress)
}

# ── intent別 TTL (秒) — Skill内蔵の _web-cache-shared.ps1 から読み込み ──
try {
    . "$PSScriptRoot/_web-cache-shared.ps1"
    $IntentTTL = $script:IntentTTL
    $NegativeTTL = $script:NegativeTTL
} catch {
    Write-Warning "[web_cache] constants load failed: $_ — cache miss 扱い"
    Write-CacheResult @{ hit = $false }; return
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
    Write-CacheResult @{ hit = $false }; return
}

if (-not (Test-Path $CacheDir)) {
    Write-CacheResult @{ hit = $false }; return
}

# ── クエリ正規化 + ハッシュ ──
$normalizedQuery = ($Query.Trim().ToLower() -replace '\s+', ' ')
$cacheKeyInput = "$normalizedQuery|$Intent|$MaxResults|$Locale"
# _web-cache-shared.ps1 は上で既に dot-source 済み（Skill内蔵の自己完結ヘルパー）
$cacheKey = Get-WebCacheStringHash -InputString $cacheKeyInput -HashLength 16

$cachePath = Join-Path $CacheDir "$cacheKey.json"

if (-not (Test-Path $cachePath)) {
    Write-CacheResult @{ hit = $false }; return
}

# ── キャッシュ読み込み ──
try {
    $raw = Get-Content $cachePath -Raw -Encoding utf8
    $cached = $raw | ConvertFrom-Json

    # ConvertFrom-Json は "...Z" を Kind=Utc の [datetime] に変換する。
    # [datetime]::Parse(<datetime>) は再文字列化で Kind を失い ToUniversalTime が
    # ローカル時刻として二重 TZ シフトする（age が TZ オフセット分過大→誤ミス）バグだった。
    $rawCachedAt = $cached.cached_at
    if ($rawCachedAt -is [datetime]) {
        $cachedAt = $rawCachedAt.ToUniversalTime()
    } elseif ($rawCachedAt -is [datetimeoffset]) {
        $cachedAt = $rawCachedAt.UtcDateTime
    } else {
        $cachedAt = [datetimeoffset]::Parse([string]$rawCachedAt, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal).UtcDateTime
    }
    $age = ((Get-Date).ToUniversalTime() - $cachedAt).TotalSeconds

    # _negative は negative cache 時のみ存在する。StrictMode 下での「プロパティ不在」例外を防ぐ。
    $isNegative = [bool]($cached.PSObject.Properties['_negative'] -and $cached._negative)
    $ttl = if ($isNegative) {
        $NegativeTTL
    } else {
        if ($IntentTTL.ContainsKey($Intent)) { $IntentTTL[$Intent] } else { $IntentTTL["default"] }
    }

    if ($age -gt $ttl) {
        # TTL 超過 → キャッシュミス（ファイルは Set-WebCache 側で上書きされる）
        Write-CacheResult @{ hit = $false }; return
    }

    if ($isNegative) {
        Write-Warning "[web_cache] negative cache hit: query='$Query' intent=$Intent age=${age}s"
    }

    Write-CacheResult @{
        hit         = $true
        data        = $cached.data
        negative    = $isNegative
        age_seconds = [int]$age
    }
    return
} catch {
    Write-Warning "[web_cache] read error: $_ path=$cachePath"
    Write-CacheResult @{ hit = $false }; return
}
