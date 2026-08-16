<#
.SYNOPSIS
    外部依存アダプタ（CLIエントリポイント）。
.DESCRIPTION
    DeepDiveResearch.psm1 の Resolve-SkillDependencies を呼び出し、
    唯一の外部依存である兄弟Skill cc-local-web-research の解決結果を
    stdout に JSON 形式で出力する。自己完結型であり、workspace専用の
    src/shared や WORKSPACE_ROOT には依存しない。
.PARAMETER LocalWebResearchRootOverride
    兄弟Skill cc-local-web-research のルートを明示指定する場合に使用する
    （既定は自スキルの同梱構造からの相対解決）。
#>
[CmdletBinding()]
param(
    [string]$LocalWebResearchRootOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'DeepDiveResearch.psm1'
try {
    Import-Module $modulePath -Force
} catch {
    [Console]::Error.WriteLine("[ERROR] module_load_failed: $_")
    exit 2
}

$result = Resolve-SkillDependencies -LocalWebResearchRootOverride $LocalWebResearchRootOverride

$hasUnresolved = @($result.Dependencies | Where-Object { $_.Status -eq 'unresolved' }).Count -gt 0
foreach ($dep in $result.Dependencies) {
    if ($dep.Status -eq 'unresolved') {
        [Console]::Error.WriteLine("[ERROR] dependency_unresolved: $($dep.Name) (required=$($dep.Required), actual=$($dep.Actual))")
    }
}

# stdout JSON 出力（paths フィールドで解決済みパスを提供）
$jsonOutput = @{
    schemaVersion = '1.0'
    dependencies  = @($result.Dependencies | ForEach-Object {
            @{
                name     = $_.Name
                status   = $_.Status
                required = $_.Required
                actual   = $_.Actual
            }
        })
    paths         = $result.Paths
} | ConvertTo-Json -Depth 4

Write-Output $jsonOutput

# 解決済みパスは JSON 出力に含まれる paths フィールドから取得可能。
# 呼び出し元が stdout JSON をパースし、自プロセスで環境変数を適用する責務を持つ。

exit ($(if ($hasUnresolved) { 2 } else { 0 }))
