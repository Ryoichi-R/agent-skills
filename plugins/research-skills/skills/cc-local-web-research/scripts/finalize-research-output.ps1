<#
.SYNOPSIS
    調査結果 Markdown と schema-version-log を原子的に確定する（WI-6）。

.DESCRIPTION
    SKILL.md Phase D の手書き「原子的書き込み手順」を委譲する。
    手順: tmp 書込（research md + schema-version-log）→ validate-output 実行 →
    rename 2 連。2 回目（log）の rename が失敗した場合は 1 回目（md）を rename-back で
    ロールバックし、「Markdown だけ確定」状態を生じさせない。冪等性（既存同名スキップ）も担う。

    タイムスタンプは UTC（`(Get-Date).ToUniversalTime()`）で生成する。
    旧手順はローカル時刻に Z を付与していたバグがあった。

.PARAMETER MarkdownContent
    確定する研究 Markdown の全文（末尾 <!-- JSON: {...} --> コメントを含む）。

.PARAMETER SchemaVersion
    schema-version-log に記録する schema_version。既定 "1.0"。

.PARAMETER OutputDir
    research md の出力先。既定 result/research（repo root 相対）。

.PARAMETER LogDir
    schema-version-log の出力先。既定 schema-version-log（repo root 相対）。

.PARAMETER Timestamp
    出力ファイル名タイムスタンプ。空=UTC 現在時刻（yyyyMMddTHHmmssZ）。冪等性テスト用に明示指定可。

.PARAMETER ValidatorPath
    検証スクリプトパス。空=同ディレクトリの validate-output.ps1。

.PARAMETER EvidenceDir
    expected artifacts manifest と安全な失敗要約の格納先。空の場合は
    `<OutputDir>/.run-state/<Timestamp>`。

.PARAMETER FaultInjectLogRename
    テスト専用: ログの rename を強制失敗させロールバック経路を検証する。

.OUTPUTS
    stdout に status JSON。終了コード: 0=確定 or 冪等スキップ, 1=異常（部分確定は残さない）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MarkdownContent,
    [string]$SchemaVersion = "1.0",
    [string]$OutputDir = "result/research",
    [string]$LogDir = "schema-version-log",
    [string]$Timestamp = "",
    [string]$ValidatorPath = "",
    [string]$EvidenceDir = "",
    [switch]$FaultInjectLogRename
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-FinalizeResult {
    param([Parameter(Mandatory)][hashtable]$Result)
    Write-Output ($Result | ConvertTo-Json -Compress)
}

# ── repo root 解決（CWD 非依存）──
$repoRoot = git -C $PSScriptRoot rev-parse --show-toplevel 2>$null
if (-not $repoRoot -or -not (Test-Path $repoRoot)) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..") -ErrorAction SilentlyContinue).Path
}
$repoRootNorm = ($repoRoot -replace '\\', '/').TrimEnd('/')

if (-not [IO.Path]::IsPathRooted($OutputDir)) { $OutputDir = Join-Path $repoRoot $OutputDir }
if (-not [IO.Path]::IsPathRooted($LogDir)) { $LogDir = Join-Path $repoRoot $LogDir }

# ── UTC タイムスタンプ（ローカル時刻に Z を付けない）──
if ([string]::IsNullOrEmpty($Timestamp)) {
    $Timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
}

if ([string]::IsNullOrEmpty($ValidatorPath)) {
    $ValidatorPath = Join-Path $PSScriptRoot 'validate-output.ps1'
}

New-Item -ItemType Directory -Force -Path $OutputDir, $LogDir | Out-Null

$mdFinal  = Join-Path $OutputDir "research_$Timestamp.md"
$logFinal = Join-Path $LogDir "$Timestamp.json"
$mdTmp    = Join-Path $OutputDir ".research_$Timestamp.md.tmp"
$logTmp   = Join-Path $LogDir ".$Timestamp.json.tmp"

if ([string]::IsNullOrEmpty($EvidenceDir)) {
    $EvidenceDir = Join-Path (Join-Path $OutputDir '.run-state') $Timestamp
}
$expectedManifestPath = Join-Path $EvidenceDir 'expected-artifacts.manifest.json'
$failureSummaryPath = Join-Path $EvidenceDir 'failure-summary.json'

function Get-EvidenceRelativePath {
    param([Parameter(Mandatory)][string]$Target)
    return ([IO.Path]::GetRelativePath($EvidenceDir, $Target) -replace '\\', '/')
}

function Write-ExpectedArtifactsManifest {
    param([Parameter(Mandatory)][ValidateSet('complete', 'failed', 'unknown')][string]$ObservedStatus)

    New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
    $manifest = [ordered]@{
        schema_version = '1.0'
        skill = 'cc-local-web-research'
        run_id = $Timestamp
        observed_status = $ObservedStatus
        expected_artifacts = @(
            [ordered]@{
                path = (Get-EvidenceRelativePath -Target $mdFinal)
                required_for = @('complete')
                description = 'Validated research Markdown.'
            },
            [ordered]@{
                path = (Get-EvidenceRelativePath -Target $logFinal)
                required_for = @('complete')
                description = 'Schema-version audit record.'
            },
            [ordered]@{
                path = 'failure-summary.json'
                required_for = @('failed')
                description = 'Redacted fixed-code finalize failure evidence.'
            }
        )
    }
    $tmpPath = "$expectedManifestPath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, (($manifest | ConvertTo-Json -Depth 10) + "`n"), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmpPath -Destination $expectedManifestPath -Force
}

function Write-FailureEvidence {
    param([Parameter(Mandatory)][ValidateSet('validation_failed', 'log_rename_failed', 'finalize_failed', 'incomplete_existing_output')][string]$Reason)

    Write-ExpectedArtifactsManifest -ObservedStatus 'failed'
    $summary = [ordered]@{
        schema_version = '1.0'
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        skill = 'cc-local-web-research'
        run_id = $Timestamp
        reason_code = $Reason
    }
    [System.IO.File]::WriteAllText($failureSummaryPath, (($summary | ConvertTo-Json) + "`n"), [System.Text.UTF8Encoding]::new($false))
}

Write-ExpectedArtifactsManifest -ObservedStatus 'unknown'

function Get-RepoRelative {
    param([string]$P)
    $n = ($P -replace '\\', '/')
    if ($n.StartsWith($repoRootNorm + '/', [StringComparison]::OrdinalIgnoreCase)) {
        return $n.Substring($repoRootNorm.Length + 1)
    }
    return $n
}

# ── 冪等性: md と schema-version log の両方が存在する場合だけスキップ ──
if (Test-Path $mdFinal) {
    if (-not (Test-Path -LiteralPath $logFinal -PathType Leaf)) {
        Write-FailureEvidence -Reason 'incomplete_existing_output'
        Write-FinalizeResult @{ status = 'error'; reason = 'incomplete_existing_output' }
        exit 1
    }
    Write-ExpectedArtifactsManifest -ObservedStatus 'complete'
    Write-FinalizeResult @{ status = "skipped"; reason = "already_exists"; output_file = (Get-RepoRelative $mdFinal); log_file = (Get-RepoRelative $logFinal) }
    exit 0
}

# ── 残留 tmp の掃除 ──
Remove-Item $mdTmp, $logTmp -Force -ErrorAction SilentlyContinue

try {
    # 1. research md を tmp へ書込
    [System.IO.File]::WriteAllText($mdTmp, $MarkdownContent, [System.Text.UTF8Encoding]::new($false))

    # 2. バリデータ実行（失敗時は tmp を残さず終了）
    & pwsh -NoProfile -File $ValidatorPath -Path $mdTmp 2>$null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item $mdTmp, $logTmp -Force -ErrorAction SilentlyContinue
        Write-FailureEvidence -Reason 'validation_failed'
        Write-FinalizeResult @{ status = "error"; reason = "validation_failed"; exit_code = $LASTEXITCODE }
        exit 1
    }

    # 3. schema-version-log を tmp へ書込
    $logObj = [ordered]@{
        timestamp      = (Get-Date).ToUniversalTime().ToString('o')
        schema_version = $SchemaVersion
        output_file    = (Get-RepoRelative $mdFinal)
    }
    [System.IO.File]::WriteAllText($logTmp, (($logObj | ConvertTo-Json) + "`n"), [System.Text.UTF8Encoding]::new($false))

    # 4. rename 1: md tmp → final
    Move-Item -Path $mdTmp -Destination $mdFinal -Force

    # 5. rename 2: log tmp → final（失敗時は md を rename-back でロールバック）
    try {
        if ($FaultInjectLogRename) { throw "fault_inject_log_rename" }
        Move-Item -Path $logTmp -Destination $logFinal -Force
    } catch {
        # ロールバック: 確定済み md を tmp へ戻し、両 tmp を削除（部分確定を残さない）
        try { Move-Item -Path $mdFinal -Destination $mdTmp -Force } catch { }
        Remove-Item $mdTmp, $logTmp -Force -ErrorAction SilentlyContinue
        Write-FailureEvidence -Reason 'log_rename_failed'
        Write-FinalizeResult @{ status = "error"; reason = "log_rename_failed"; detail = "$_" }
        exit 1
    }

    Write-ExpectedArtifactsManifest -ObservedStatus 'complete'
    Write-FinalizeResult @{ status = "ok"; output_file = (Get-RepoRelative $mdFinal); log_file = (Get-RepoRelative $logFinal) }
    exit 0
} catch {
    Remove-Item $mdTmp, $logTmp -Force -ErrorAction SilentlyContinue
    Write-FailureEvidence -Reason 'finalize_failed'
    Write-FinalizeResult @{ status = "error"; reason = "finalize_failed"; detail = "$_" }
    exit 1
}
