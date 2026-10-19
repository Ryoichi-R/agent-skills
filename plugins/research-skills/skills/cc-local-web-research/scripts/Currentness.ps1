# Corpus currentness records are data, never executable instructions.

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
function Read-CorpusCurrentness {
    param([string]$Root)
    $path = Join-Path $Root '.research-policy/currentness.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $path = Assert-ResearchPath -Path $path -Root $Root
    if ((Get-Item -LiteralPath $path).Length -gt 2MB) { throw 'currentness_policy_too_large' }
    $json = Get-Content -LiteralPath (Assert-ScriptFileIoPath -Path ($path)) -Raw -Encoding utf8
    if (-not (Test-Json -Json $json -SchemaFile (Join-Path $PSScriptRoot '../references/currentness-policy.schema.json') -ErrorAction SilentlyContinue)) {
        throw 'currentness_policy_schema_invalid'
    }
    $policy = $json | ConvertFrom-Json -AsHashtable
    $bound = @{}
    foreach ($entry in @($policy.documents) + @($policy.report)) {
        $relative = ([string]$entry.path) -replace '\\', '/'
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)|[:\r\n]') { throw 'currentness_path_invalid' }
        if ($bound.ContainsKey($relative)) { throw 'currentness_path_repeated' }
        $full = Assert-ResearchPath -Path (Join-Path $Root $relative) -Root $Root
        if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne $entry.sha256) { throw 'currentness_hash_mismatch' }
        $bound[$relative] = $true
    }
    $ids = @{}
    foreach ($finding in $policy.findings) {
        if ($ids.ContainsKey($finding.id)) { throw 'currentness_id_repeated' }
        $ids[$finding.id] = $true
        foreach ($location in $finding.locations) {
            if (-not $bound.ContainsKey($location.path) -or $location.path -eq $policy.report.path) { throw 'currentness_unbound_location' }
        }
    }
    $policy['fingerprint'] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $policy
}

function Get-CorpusCurrentnessNote {
    param([AllowNull()][hashtable]$Policy, [AllowEmptyCollection()][object[]]$Matches, [string]$Query)
    if (-not $Policy) { return '' }
    $paths = @($Matches | ForEach-Object { ([string]$_.path) -replace '\\', '/' })
    $relevant = @($Policy.findings | Where-Object {
        $finding = $_
        $documentHit = @($finding.locations | Where-Object { $_.path -in $paths }).Count -gt 0
        $topicHit = @($finding.keywords | Where-Object { $Query.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
        $documentHit -or $topicHit
    })
    if ($relevant.Count -eq 0) { return '' }
    $record = [ordered]@{
        checked_at = $Policy.checked_at
        report = $Policy.report.path
        policy_sha256 = $Policy.fingerprint
        findings = $relevant
    }
    return '[現行性確認データ: 原文の数値を現行とみなさず、action・適用条件・公式出典を確認。確認日時点の記録であり恒久の現行保証ではない。]' + "`n" + ($record | ConvertTo-Json -Depth 12 -Compress)
}
