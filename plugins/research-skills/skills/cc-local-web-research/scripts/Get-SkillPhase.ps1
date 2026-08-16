# PowerShell 構文制約: param() はスクリプトファイルの先頭に配置必須
param(
    [string]$ConfigPath,   # 後方互換のため残す（無視）— 将来削除予定
    [DateTime]$NowUtc,     # 後方互換のため残す（無視）— 同上
    [switch]$AsString,     # 指定時のみ文字列を返す。既定は PSCustomObject を返し後方互換を維持
    [DateTime]$TestNowUtc = [DateTime]::UtcNow  # テスト用時刻注入点
)

# --- 初期化（param() の後に配置） ---

# パス解決: repoRoot 基準（全スクリプト共通パターン）
$repoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) {
    # 非Git環境: Phase1 フォールバック（throw しない。CI コンテナ等での安全動作を保証）
    [Console]::Error.WriteLine("[E_PHASE_NO_GIT] git リポジトリ外での実行を検出。Phase1 にフォールバックします。")
    if ($AsString) { return "Phase1" } else { return [PSCustomObject]@{ Phase = "Phase1" } }
}

# 非推奨パラメータの削除期限（共通設定ファイルから読み込み）
# 正本: <repoRoot>/lib/deprecation-config.json
function Initialize-DeprecationDeadline {
    $deprecationConfigPath = Join-Path $repoRoot "lib" "deprecation-config.json"
    $defaultDeadline = [DateTime]::new(2026, 6, 30, 0, 0, 0, [DateTimeKind]::Utc)
    if (-not (Test-Path $deprecationConfigPath)) {
        [Console]::Error.WriteLine("[E_DEPR_CONFIG_MISSING] deprecation-config.json not found at $deprecationConfigPath. Using hardcoded default.")
        return $defaultDeadline
    }
    try {
        $cfg = Get-Content $deprecationConfigPath -Raw | ConvertFrom-Json
        $key = 'Get-SkillPhase.ConfigPath'
        if (-not $cfg.PSObject.Properties[$key]) {
            throw "キー '$key' が未定義"
        }
        [DateTime]::Parse($cfg.$key, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        [Console]::Error.WriteLine("[E_DEPR_CONFIG_INVALID] deprecation-config.json の読込/パースに失敗しました: $_. Using hardcoded default.")
        $defaultDeadline
    }
}
$script:DeprecationDeadline = Initialize-DeprecationDeadline

# 非推奨パラメータ使用時の警告（-Verbose 時のみ出力して通常運用ログを汚さない）
if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    Write-Verbose "[Deprecated] -ConfigPath は無視されます。$($script:DeprecationDeadline.ToString('yyyy-MM-dd')) 以降に削除予定です。"
}
if ($PSBoundParameters.ContainsKey('NowUtc')) {
    Write-Verbose "[Deprecated] -NowUtc は無視されます。$($script:DeprecationDeadline.ToString('yyyy-MM-dd')) 以降に削除予定です。"
}
# 削除期限到達時の互換破壊通知
$isPostDeadline = $TestNowUtc -gt $script:DeprecationDeadline
if ($isPostDeadline -and ($PSBoundParameters.ContainsKey('ConfigPath') -or $PSBoundParameters.ContainsKey('NowUtc'))) {
    Write-Warning "[BREAKING] -ConfigPath/-NowUtc は廃止済みです。呼び出し元を修正してください。次回メジャー更新で削除されます。"
}

$statePath = Join-Path $repoRoot ".claude" "state" "phase-state.json"

# フェイルセーフ既定値: model-config.json から current_phase を読み取る（Phase 退行防止）
$fallbackPhase = 1
$modelConfigPath = Join-Path $repoRoot ".claude" "skills" "cc-local-web-research" "references" "model-config.json"
if (Test-Path $modelConfigPath) {
    try {
        $mc = Get-Content $modelConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($mc.PSObject.Properties['current_phase'] -and $mc.current_phase -ge 1 -and $mc.current_phase -le 4) {
            $fallbackPhase = [int]$mc.current_phase
        }
    } catch {
        [Console]::Error.WriteLine("[E_PHASE_FALLBACK_READ] model-config.json フォールバック読込失敗: $_")
    }
}
$phaseStr = "Phase$fallbackPhase"

try {
    $resolvedPath = (Resolve-Path $statePath -ErrorAction Stop).Path
    $state = Get-Content $resolvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $state.PSObject.Properties['current_phase'] -or $state.current_phase -lt 1) {
        throw "current_phase が不正または未定義"
    }
    $phaseStr = "Phase$($state.current_phase)"
} catch {
    # フェイルセーフ: phase-state.json 未存在・JSON不正・current_phase欠損時は model-config.json の値にフォールバック
    [Console]::Error.WriteLine("[E_PHASE_READ] phase-state.json の読込に失敗しました。Phase$fallbackPhase にフォールバックします: $_")
}

if ($AsString) {
    $phaseStr
} else {
    [PSCustomObject]@{ Phase = $phaseStr }
}
