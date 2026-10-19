<#
.SYNOPSIS
    Deep Diveの課題・根拠・操作・予算・再開・確定を管理するCLI。
.DESCRIPTION
    init/read以外はExpectedRevision必須。実ツールはleadが操作し結果をAPIへ登録する。
    成功はstdout JSON/exit 0、拒否は固定reason_code/exit 2。生の例外や本文は出力しない。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('init', 'read', 'action', 'issue', 'evidence', 'route', 'review', 'checkpoint', 'resume', 'finalize')][string]$Operation,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$RunId,
    [string]$WorkspaceRoot = (Get-Location).Path,
    [string]$StateRoot = '',
    [string]$ParentInputPath = '',
    [string]$SourceRoot = '',
    [string]$OriginalQuery = '',
    [ValidateRange(0, 1000000)][double]$MaxMinutes = 120,
    [ValidateRange(0, 1000000)][int]$MaxWebOperations = 200,
    [string]$ActionId = '',
    [string]$ActionType = '',
    [ValidateSet('planned', 'started', 'succeeded', 'empty', 'failed', 'interrupted')][string]$ActionStatus = 'planned',
    [string]$IssueId = '',
    [string]$IssueJson = '',
    [string]$EvidenceJson = '',
    [ValidateSet('active', 'partial', 'complete', 'cancelled', 'failed')][string]$RunStatus = 'partial',
    [string]$OutputPath = '',
    [string]$OutputSha256 = '',
    [int]$ExpectedRevision = -1,
    [string]$PayloadJson = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
try {
    Import-Module (Join-Path $PSScriptRoot 'DeepDiveState.psm1') -Force
    $options = @{}
    foreach ($name in $MyInvocation.MyCommand.Parameters.Keys) {
        if ($name -notin [Management.Automation.PSCmdlet]::CommonParameters -and $name -notin [Management.Automation.PSCmdlet]::OptionalCommonParameters) {
            $options[$name] = Get-Variable -Name $name -ValueOnly
        }
    }
    $result = Invoke-DeepDiveStateCommand -Options $options
    $result | ConvertTo-Json -Depth 40
    if ($result.status -ne 'ok') { exit 2 }
    exit 0
} catch {
    $reason = $_.Exception.Message
    if ($reason -notmatch '^[a-z][a-z0-9_]{2,80}$') { $reason = 'state_operation_failed' }
    @{ status = 'error'; operation = $Operation; run_id = $RunId; reason_code = $reason } | ConvertTo-Json -Compress
    exit 2
}
