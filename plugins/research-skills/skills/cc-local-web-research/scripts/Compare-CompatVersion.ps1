param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$TargetVersion
)

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$currentVersion = [Version]$config.compatibility_version
$targetVer = [Version]$TargetVersion

[PSCustomObject]@{
    IsGreaterOrEqual = $currentVersion -ge $targetVer
    IsLessThan       = $currentVersion -lt $targetVer
}
