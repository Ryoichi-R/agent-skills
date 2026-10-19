param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$TargetVersion
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


$config = Get-Content (Assert-ScriptFileIoPath -Path ($ConfigPath) -AllowWildcards) -Raw | ConvertFrom-Json
$currentVersion = [Version]$config.compatibility_version
$targetVer = [Version]$TargetVersion

[PSCustomObject]@{
    IsGreaterOrEqual = $currentVersion -ge $targetVer
    IsLessThan       = $currentVersion -lt $targetVer
}
