<#
.SYNOPSIS
    skill-source 内のファイルに LLM API で要約を自動生成し、サイドカーまたは frontmatter に書き込む。

.DESCRIPTION
    Claude API を使用してファイルごとの要約を生成する。
    既定ではサイドカー（*.meta.yaml）に書き込み、-WriteFrontmatter 指定時のみ .md ファイルの frontmatter に直書きする。

.PARAMETER SourceRoot
    スキャン対象ディレクトリ。環境変数 CC_LWR_SOURCE_ROOT、未設定時はユーザーhome直下の skill-source（$HOME/skill-source）。

.PARAMETER Include
    対象ファイルパターン。

.PARAMETER Exclude
    除外ファイルパターン。

.PARAMETER MaxInputChars
    API に送信するファイル先頭の最大文字数。デフォルトは 4000。

.PARAMETER TimeoutSec
    1ファイルあたりの API タイムアウト（秒）。デフォルトは 30。

.PARAMETER RetryCount
    API 失敗時の最大再試行回数。デフォルトは 2。

.PARAMETER RetryBackoffSec
    再試行間のバックオフ秒数（指数増加）。デフォルトは 5。

.PARAMETER ResumeFrom
    SourceRoot からの相対パスで処理再開位置を指定。

.PARAMETER Force
    既存 summary も再生成する。

.PARAMETER WriteFrontmatter
    .md ファイルへの frontmatter 直書きを有効化。

.PARAMETER NoBackup
    frontmatter 書き込み前のバックアップを無効化。

.PARAMETER DryRun
    API 送信せず対象一覧を JSON で表示。
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SourceRoot = $env:CC_LWR_SOURCE_ROOT,

    [string[]]$Include = @("*.md", "*.txt", "*.csv", "*.yaml", "*.yml"),

    [string[]]$Exclude = @(),

    [int]$MaxInputChars = 4000,

    [int]$TimeoutSec = 30,

    [int]$RetryCount = 2,

    [int]$RetryBackoffSec = 5,

    [string]$ResumeFrom = "",

    [switch]$Force,

    [switch]$WriteFrontmatter,

    [switch]$NoBackup,

    [switch]$DryRun
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

# ── YAML スカラー共通ヘルパ（dot-source）──
. (Join-Path $PSScriptRoot '_yaml-scalar.ps1')

# ── モデル ID は references/model-config.json の default_model から解決（ハードコード廃止）──
function Get-ConfiguredModel {
    $configPath = Join-Path $PSScriptRoot '..\references\model-config.json'
    if (-not (Test-Path $configPath)) {
        throw "model-config.json が見つかりません: $configPath"
    }
    try {
        $cfg = Get-Content (Assert-ScriptFileIoPath -Path ($configPath) -AllowWildcards) -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        throw "model-config.json のパースに失敗しました: $_"
    }
    $model = $cfg.default_model
    if ([string]::IsNullOrWhiteSpace($model)) {
        throw "model-config.json に default_model が定義されていません。"
    }
    $validIds = @($cfg.models | ForEach-Object { $_.id })
    if ($validIds -notcontains $model) {
        throw "default_model '$model' が models[].id に存在しません。"
    }
    return $model
}

# ── API キー検証 ──
if (-not $DryRun) {
    if ([string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY)) {
        Write-Error "API キーが設定されていません。`$env:ANTHROPIC_API_KEY を設定してください。"
        exit 1
    }
    # モデル ID を解決（読込/検証失敗時は明示エラーで停止）
    try {
        $script:ConfiguredModel = Get-ConfiguredModel
    } catch {
        Write-Error "モデル設定の解決に失敗しました: $_"
        exit 1
    }
}

# ── SourceRoot / repo root 解決 ──
# 裸の git rev-parse は CWD 依存（別 repo を CWD にすると誤った root を拾う）。
# collect_skill_source.ps1 と同じく必ず -C $PSScriptRoot を付けて CWD 非依存にする。
$repoRoot = git -C $PSScriptRoot rev-parse --show-toplevel 2>$null
if (-not $repoRoot -or -not (Test-Path $repoRoot)) {
    $repoRoot = (Resolve-Path (Assert-ScriptFileIoPath -Path ((Join-Path $PSScriptRoot "..\..\..\.." )) -AllowWildcards) -ErrorAction SilentlyContinue).Path
}
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = Join-Path $HOME 'skill-source' }
if (-not [IO.Path]::IsPathRooted($SourceRoot)) {
    $SourceRoot = Join-Path $repoRoot $SourceRoot
}
if (-not (Test-Path $SourceRoot)) {
    Write-Error "SourceRoot が存在しません: $SourceRoot"
    exit 1
}
$resolvedRoot = (Resolve-Path (Assert-ScriptFileIoPath -Path ($SourceRoot) -AllowWildcards)).Path

# ── 派生物（要約失敗ログ）の保存先: workspace cache 配下（資料コーパスには書かない）──
# skill-source 由来の派生物は .gitignore 済みの .cache/cc-local-web-research/ に集約する。
# 環境変数 CC_LWR_CACHE_DIR で cache ディレクトリを上書き可。cache 作成不可・repo root
# 解決不可時のみ %TEMP%/cc-local-web-research/ へ退避する（collect_skill_source.ps1 と同方針）。
function Resolve-FailuresLogPath {
    param([string]$RepoRoot)
    $cacheDir = if ($env:CC_LWR_CACHE_DIR) { $env:CC_LWR_CACHE_DIR }
                elseif ($RepoRoot) { Join-Path $RepoRoot ".cache/cc-local-web-research" }
                else { $null }
    if ($cacheDir) {
        try {
            if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path (Assert-ScriptFileIoPath -Path ($cacheDir) -AllowWildcards) -Force | Out-Null }
            return (Join-Path $cacheDir ".generate-summaries-failures.json")
        } catch {
            Write-Warning "[cache_dir_failed] dir=$cacheDir error=$_ → temp fallback"
        }
    }
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) "cc-local-web-research"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path (Assert-ScriptFileIoPath -Path ($tempDir) -AllowWildcards) -Force | Out-Null }
    return (Join-Path $tempDir ".generate-summaries-failures.json")
}

# ── 機密マスキング ──
function Invoke-SecretMask {
    param([string]$Text)

    $masked = $Text

    # パターンマッチ: API キー、トークン等
    $masked = [regex]::Replace($masked,
        '(api[_-]?key|token|password|secret|bearer|authorization|private[_-]?key)\s*[:=]\s*\S+',
        '$1: [REDACTED]',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    # PEM 秘密鍵
    $masked = [regex]::Replace($masked,
        '-----BEGIN\s+(RSA\s+)?PRIVATE\s+KEY-----[\s\S]*?-----END\s+(RSA\s+)?PRIVATE\s+KEY-----',
        '[REDACTED-PEM]')

    # 高エントロピートークン（32文字以上の英数字+記号のみ）
    $tokenPattern = '[A-Za-z0-9+/=_\-]{32,}'
    $tokenMatches = [regex]::Matches($masked, $tokenPattern)
    $highEntropyCount = 0
    foreach ($tm in $tokenMatches) {
        $entropy = Get-ShannonEntropy $tm.Value
        if ($entropy -gt 4.0) {
            $highEntropyCount++
            $masked = $masked.Replace($tm.Value, '[REDACTED-TOKEN]')
        }
    }

    # マスク後再検査: [REDACTED] 系以外の値が残っていないか
    $remainingSecrets = [regex]::Matches($masked,
        '(api[_-]?key|token|password|secret|bearer|authorization|private[_-]?key)\s*[:=]\s*(?!\[REDACTED)\S+',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    if ($remainingSecrets.Count -gt 0 -or $highEntropyCount -ge 5) {
        return $null  # 送信中止
    }

    return $masked
}

function Get-ShannonEntropy {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0.0 }
    $freq = @{}
    foreach ($c in $Text.ToCharArray()) {
        if ($freq.ContainsKey($c)) { $freq[$c]++ } else { $freq[$c] = 1 }
    }
    $entropy = 0.0
    $len = $Text.Length
    foreach ($count in $freq.Values) {
        $p = $count / $len
        if ($p -gt 0) { $entropy -= $p * [Math]::Log($p, 2) }
    }
    return $entropy
}

# ── Read-Frontmatter（collect_skill_source.ps1 と同一ロジック）──
function Read-Frontmatter {
    param([string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return $null }
    $text = $Content.TrimStart([char]0xFEFF)
    if ($text.StartsWith('+++') -or $text.StartsWith('{')) { return $null }
    if (-not ($text -match '^---\s*[\r\n]')) { return $null }
    $afterFirst = $text.Substring($text.IndexOf("`n") + 1)
    $endMatch = [regex]::Match($afterFirst, '(?m)^---\s*$')
    if (-not $endMatch.Success) { return $null }
    $fmBlock = $afterFirst.Substring(0, $endMatch.Index)
    $summaryMatch = [regex]::Match($fmBlock, '(?m)^summary\s*:\s*(.+)$')
    if (-not $summaryMatch.Success) { return $null }
    $val = ConvertFrom-YamlScalar -Value $summaryMatch.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    return $val
}

# ── Write-Frontmatter（厳しく限定）──
function Write-Frontmatter {
    param(
        [string]$FilePath,
        [string]$Summary,
        [bool]$CreateBackup
    )

    $content = Get-Content (Assert-ScriptFileIoPath -Path ($FilePath) -AllowWildcards) -Raw -Encoding utf8
    $ext = [IO.Path]::GetExtension($FilePath).ToLower()

    # 直書き可能条件チェック
    if ($ext -ne '.md') { return $false }

    # BOM チェック
    $bytes = [IO.File]::ReadAllBytes((Assert-ScriptFileIoPath -Path ($FilePath)))
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $isUtf8 = $true  # 基本的に UTF-8 と仮定

    $text = $content.TrimStart([char]0xFEFF)
    if ($text.StartsWith('---') -or $text.StartsWith('+++') -or $text.StartsWith('{')) {
        return $false  # 既存 frontmatter あり → サイドカー
    }

    if (-not $isUtf8) { return $false }

    # バックアップ作成
    if ($CreateBackup) {
        Copy-Item (Assert-ScriptFileIoPath -Path ($FilePath) -AllowWildcards -Recurse) (Assert-ScriptFileIoPath -Path ("$FilePath.bak")) -Force
    }

    # 改行コード検出
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }

    # frontmatter 挿入（summary は YAML スカラーとして安全にエスケープ）
    $scalar = ConvertTo-YamlScalar -Value $Summary
    $expectedSummary = ConvertFrom-YamlScalar -Value $scalar  # 単一行化後の期待値（検証用）
    $fmBlock = "---${newline}summary: $scalar${newline}---${newline}"
    $newContent = $fmBlock + $content

    # BOM 保持
    if ($hasBom) {
        $encoding = New-Object System.Text.UTF8Encoding($true)
    } else {
        $encoding = New-Object System.Text.UTF8Encoding($false)
    }
    [IO.File]::WriteAllText((Assert-ScriptFileIoPath -Path ($FilePath)), $newContent, $encoding)

    # 再読み取り検証（単一行化後の期待値と比較）
    $verifyContent = Get-Content (Assert-ScriptFileIoPath -Path ($FilePath) -AllowWildcards) -Raw -Encoding utf8
    $verified = Read-Frontmatter -Content $verifyContent
    if ($verified -ne $expectedSummary) {
        # 検証失敗: バックアップから復元
        if ($CreateBackup -and (Test-Path "$FilePath.bak")) {
            Move-Item (Assert-ScriptFileIoPath -Path ("$FilePath.bak") -AllowWildcards -Recurse) (Assert-ScriptFileIoPath -Path ($FilePath)) -Force
        }
        Write-Warning "[write_frontmatter_verify_failed] path=$FilePath"
        return $false
    }

    return $true
}

# ── Write-Sidecar ──
function Write-Sidecar {
    param(
        [string]$FilePath,
        [string]$Summary
    )
    $sidecarPath = "$FilePath.meta.yaml"
    "summary: $(ConvertTo-YamlScalar -Value $Summary)" | Set-Content -Path (Assert-ScriptFileIoPath -Path ($sidecarPath) -AllowWildcards) -Encoding utf8 -NoNewline
}

# ── Claude API 呼び出し ──
function Invoke-ClaudeApi {
    param(
        [string]$Content,
        [string]$FileName
    )

    $prompt = @"
<document>
$Content
</document>

上記のドキュメント（ファイル名: $FileName）の要約を、日本語で1〜2文（100文字以内）で生成してください。
ドキュメントの主題と重要なキーワードを含めてください。
要約のみを出力し、説明や前置きは不要です。
"@

    $body = @{
        model = $script:ConfiguredModel
        max_tokens = 200
        messages = @(
            @{ role = "user"; content = $prompt }
        )
    } | ConvertTo-Json -Depth 4

    $headers = @{
        "x-api-key" = $env:ANTHROPIC_API_KEY
        "anthropic-version" = "2023-06-01"
        "content-type" = "application/json"
    }

    $response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" `
        -Method Post -Headers $headers -Body $body `
        -TimeoutSec $TimeoutSec -ErrorAction Stop

    if ($response.content -and $response.content.Count -gt 0) {
        return $response.content[0].text.Trim()
    }
    throw "API レスポンスに content がありません"
}

# ── ファイル一覧取得 ──
$allFiles = @(Get-ChildItem -Path $resolvedRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $file = $_
    $matched = $false
    foreach ($pattern in $Include) {
        if ($file.Name -like $pattern) { $matched = $true; break }
    }
    if (-not $matched) { return $false }
    foreach ($pattern in $Exclude) {
        if ($file.Name -like $pattern) { return $false }
    }
    # 生成物を除外
    if ($file.Name -like '*.meta.yaml' -or $file.Name -like '*.bak' -or
        $file.Name -eq '.search-index.json' -or $file.Name -eq '.search-index.lock' -or
        $file.Name -eq '.generate-summaries-failures.json' -or
        $file.Name -like '*.tmp.*.json') { return $false }
    # 隠しディレクトリ除外
    $relativePath = $file.FullName.Substring($resolvedRoot.Length + 1)
    $parts = $relativePath -split '[/\\]'
    foreach ($part in $parts[0..([Math]::Max(0, $parts.Length - 2))]) {
        if ($part -match '^\.') { return $false }
    }
    return $true
})

# ResumeFrom フィルタ
if ($ResumeFrom) {
    $resumeNorm = $ResumeFrom -replace '\\', '/'
    $filtered = @()
    $found = $false
    foreach ($f in ($allFiles | Sort-Object FullName)) {
        $rel = ($f.FullName.Substring($resolvedRoot.Length + 1) -replace '\\', '/')
        if ($rel -eq $resumeNorm) { $found = $true }
        if ($found) { $filtered += $f }
    }
    $allFiles = $filtered
}

# 既存 summary がある場合はスキップ（-Force 除外時）
$targets = @()
foreach ($f in $allFiles) {
    $relPath = $f.FullName.Substring($resolvedRoot.Length + 1) -replace '\\', '/'

    if (-not $Force) {
        # サイドカー確認
        $sidecarPath = "$($f.FullName).meta.yaml"
        if (Test-Path $sidecarPath) {
            $scContent = Get-Content (Assert-ScriptFileIoPath -Path ($sidecarPath) -AllowWildcards) -Raw -Encoding utf8 -ErrorAction SilentlyContinue
            if ($scContent -and $scContent -match '(?m)^summary\s*:\s*.+') { continue }
        }
        # frontmatter 確認
        if ($f.Extension -eq '.md') {
            $mdContent = Get-Content (Assert-ScriptFileIoPath -Path ($f.FullName) -AllowWildcards) -Raw -Encoding utf8 -ErrorAction SilentlyContinue
            if ($mdContent) {
                $fmSummary = Read-Frontmatter -Content $mdContent
                if ($fmSummary) { continue }
            }
        }
    }

    $targets += @{
        file     = $f
        relPath  = $relPath
    }
}

Write-Host "対象ファイル: $($targets.Count) 件（全体: $($allFiles.Count) 件）"

# ── DryRun モード ──
if ($DryRun) {
    $dryRunResult = $targets | ForEach-Object {
        @{ path = $_.relPath; sizeBytes = $_.file.Length }
    }
    $dryRunResult | ConvertTo-Json -Depth 2
    Write-Host "`n初回実行時は -DryRun を推奨します。API 送信前に対象を確認してください。"
    exit 0
}

# ── 起動時確認 ──
if (-not $PSCmdlet.ShouldProcess("$($targets.Count) 件のファイルを Claude API に送信")) {
    Write-Host "処理がキャンセルされました。"
    exit 0
}

# ── バッチ処理 ──
$failures = @()
$successCount = 0

foreach ($target in $targets) {
    $f = $target.file
    $relPath = $target.relPath

    Write-Host "[$($successCount + $failures.Count + 1)/$($targets.Count)] $relPath ... " -NoNewline

    try {
        $content = Get-Content (Assert-ScriptFileIoPath -Path ($f.FullName) -AllowWildcards) -Raw -Encoding utf8 -ErrorAction Stop

        # 先頭 MaxInputChars 文字に制限
        if ($content.Length -gt $MaxInputChars) {
            $content = $content.Substring(0, $MaxInputChars)
        }

        # 機密マスキング
        $maskedContent = Invoke-SecretMask -Text $content
        if ($null -eq $maskedContent) {
            Write-Host "SKIP (機密検出)"
            $failures += @{ path = $relPath; error = "secret_detected"; timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
            continue
        }

        # API 呼び出し（リトライ付き）
        $summary = $null
        $lastError = $null
        for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
            try {
                $summary = Invoke-ClaudeApi -Content $maskedContent -FileName $f.Name
                break
            } catch {
                $lastError = $_
                if ($attempt -lt $RetryCount) {
                    $backoff = $RetryBackoffSec * [Math]::Pow(2, $attempt)
                    # HTTP 429: Retry-After ヘッダに従う
                    if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 429) {
                        $retryAfter = $_.Exception.Response.Headers['Retry-After']
                        if ($retryAfter) { $backoff = [Math]::Max($backoff, [int]$retryAfter) }
                    }
                    Write-Host "RETRY($($attempt + 1)) " -NoNewline
                    Start-Sleep -Seconds $backoff
                }
            }
        }

        if (-not $summary) {
            Write-Host "FAIL"
            $failures += @{ path = $relPath; error = "$lastError"; timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
            continue
        }

        # 要約の書き込み
        $written = $false
        if ($WriteFrontmatter -and $f.Extension -eq '.md') {
            $written = Write-Frontmatter -FilePath $f.FullName -Summary $summary -CreateBackup (-not $NoBackup)
        }

        if (-not $written) {
            Write-Sidecar -FilePath $f.FullName -Summary $summary
        }

        $successCount++
        Write-Host "OK"

    } catch {
        Write-Host "ERROR: $_"
        $failures += @{ path = $relPath; error = "$_"; timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
    }
}

# ── 失敗一覧の出力（派生物は workspace cache 配下: 資料コーパスには書かない）──
$failuresPath = Resolve-FailuresLogPath -RepoRoot $repoRoot
# 旧版が SourceRoot(G:) 直下へ書いた失敗ログが残っていれば掃除する（派生物を G: に残さない）。
$legacyFailures = Join-Path $resolvedRoot ".generate-summaries-failures.json"
if ((Test-Path $legacyFailures) -and ($legacyFailures -ne $failuresPath)) {
    Remove-Item (Assert-ScriptFileIoPath -Path ($legacyFailures) -AllowWildcards) -Force -ErrorAction SilentlyContinue
}
if ($failures.Count -gt 0) {
    $failures | ConvertTo-Json -Depth 2 | Set-Content -Path (Assert-ScriptFileIoPath -Path ($failuresPath) -AllowWildcards) -Encoding utf8
    Write-Host "`n失敗: $($failures.Count) 件 → $failuresPath"
} elseif (Test-Path $failuresPath) {
    Remove-Item (Assert-ScriptFileIoPath -Path ($failuresPath) -AllowWildcards) -Force
}

Write-Host "`n完了: 成功=$successCount, 失敗=$($failures.Count), スキップ=$($allFiles.Count - $targets.Count)"
