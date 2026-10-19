<#
.SYNOPSIS
    local-web-research と deep-dive-research の引継ぎcontextを管理する。
.DESCRIPTION
    Markdown本文のmetadataを膨らませず、成果物と同じディレクトリに
    <report-base>.context.json を原子的に保存する。秘密情報や本文を保存せず、
    report_sha256 と実行条件だけを保持する。
#>

Set-StrictMode -Version Latest

function Get-ResearchFileSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "report_not_found:$Path"
    }

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
        }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-ResearchContextPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ReportPath)

    $full = [System.IO.Path]::GetFullPath($ReportPath)
    $dir = [System.IO.Path]::GetDirectoryName($full)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($full)
    return [System.IO.Path]::Combine($dir, "$base.context.json")
}

function New-ResearchContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [string]$RunId = ([Guid]::NewGuid().ToString('N')),
        [string]$OriginalQuery = 'unknown',
        [AllowNull()][string]$SourceRoot = $null,
        [ValidateSet('success', 'partial', 'failed', 'not_run', 'unknown')]
        [string]$LocalSearchStatus = 'unknown',
        [ValidateSet('success', 'partial', 'failed', 'not_run', 'unknown')]
        [string]$WebSearchStatus = 'unknown',
        [hashtable]$SearchTerms = @{},
        [string[]]$ExcludedConditions = @(),
        [string[]]$KnownLimitations = @(),
        [string]$CreatedAt = ''
    )

    $fullReport = [System.IO.Path]::GetFullPath($ReportPath)
    $created = if ([string]::IsNullOrWhiteSpace($CreatedAt)) {
        (Get-Date).ToUniversalTime().ToString('o')
    } else { $CreatedAt }

    return [ordered]@{
        schema_version       = '1.0'
        run_id               = $RunId
        report_path          = $fullReport
        report_sha256        = Get-ResearchFileSha256 -Path $fullReport
        original_query       = if ([string]::IsNullOrWhiteSpace($OriginalQuery)) { 'unknown' } else { $OriginalQuery }
        source_root          = $SourceRoot
        created_at           = $created
        local_search_status  = $LocalSearchStatus
        web_search_status    = $WebSearchStatus
        search_terms         = $SearchTerms
        excluded_conditions  = @($ExcludedConditions)
        known_limitations    = @($KnownLimitations)
    }
}

function Write-ResearchContext {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [string]$ContextPath = ''
    )

    if (-not (Test-Json -Json ($Context | ConvertTo-Json -Depth 12) -SchemaFile (Join-Path $PSScriptRoot '../references/research-context.schema.json') -ErrorAction SilentlyContinue)) { throw 'context_invalid_schema' }
    Assert-ResearchSafeText -Text ($Context | ConvertTo-Json -Depth 12)
    $target = if ([string]::IsNullOrWhiteSpace($ContextPath)) {
        Get-ResearchContextPath -ReportPath ([string]$Context.report_path)
    } else { [System.IO.Path]::GetFullPath($ContextPath) }

    $parent = [System.IO.Path]::GetDirectoryName($target)
    Assert-ResearchPath -Path $target -Root $parent | Out-Null
    Assert-ResearchPath -Path $Context.report_path -Root ([IO.Path]::GetDirectoryName($Context.report_path)) | Out-Null
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = ($Context | ConvertTo-Json -Depth 12) + "`n"
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $tmp = "$target.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $target -Force
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
    return $target
}

function Test-ResearchContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$ContextPath, [string]$ReportPath = '')

    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $ContextPath -PathType Leaf)) {
        return @{ Valid = $false; Errors = @('context_not_found'); Context = $null }
    }
    try {
        Assert-ResearchPath -Path $ContextPath -Root ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ContextPath))) | Out-Null
        $json = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8
        if (-not (Test-Json -Json $json -SchemaFile (Join-Path $PSScriptRoot '../references/research-context.schema.json') -ErrorAction SilentlyContinue)) {
            return @{ Valid = $false; Errors = @('context_invalid_schema'); Context = $null }
        }
        Assert-ResearchSafeText -Text $json
        $context = $json | ConvertFrom-Json -ErrorAction Stop
        $boundReport = if ($ReportPath) { [IO.Path]::GetFullPath($ReportPath) } else { [IO.Path]::GetFullPath($context.report_path) }
        if ($boundReport -ne [IO.Path]::GetFullPath($context.report_path)) { throw 'context_report_mismatch' }
        Assert-ResearchPath -Path $boundReport -Root ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ContextPath))) | Out-Null
    }
    catch { return @{ Valid = $false; Errors = @('context_invalid_json'); Context = $null } }

    foreach ($name in @('schema_version', 'run_id', 'report_path', 'report_sha256', 'original_query', 'created_at', 'local_search_status', 'web_search_status')) {
        if (-not ($context.PSObject.Properties.Name -contains $name)) { $errors.Add("missing:$name") }
    }
    if ($context.report_sha256 -and $context.report_sha256 -notmatch '^[0-9a-fA-F]{64}$') { $errors.Add('invalid:report_sha256') }
    $validStatuses = @('success', 'partial', 'failed', 'not_run', 'unknown')
    foreach ($name in @('local_search_status', 'web_search_status')) {
        if ($context.$name -and $context.$name -notin $validStatuses) { $errors.Add("invalid:$name") }
    }
    if ($context.report_path -and -not (Test-Path -LiteralPath $context.report_path -PathType Leaf)) { $errors.Add('report_not_found') }
    elseif ($context.report_path -and $context.report_sha256) {
        try {
            if ((Get-ResearchFileSha256 -Path $context.report_path) -ne ([string]$context.report_sha256).ToLowerInvariant()) { $errors.Add('report_hash_mismatch') }
        } catch { $errors.Add('report_unreadable') }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors); Context = $context }
}

function Assert-ResearchSafeText {
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '(?i)(?:api[_-]?key|access[_-]?token|password|secret)\s*[=:]\s*["'']?[A-Za-z0-9_+/=-]{8,}|Bearer\s+[A-Za-z0-9._~+/-]{8,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bsk-[A-Za-z0-9_-]{20,}') {
        throw 'sensitive_content_rejected'
    }
}

function Test-ResearchMacSystemAlias {
    # macOS の /var・/tmp・/etc は OS が用意する /private/* へのシンボリックリンクで、一時ディレクトリは必ずこれを経由する。
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item)
    if (-not $IsMacOS) { return $false }
    $name = $Item.FullName.TrimEnd('/')
    if ($name -notin @('/var', '/tmp', '/etc')) { return $false }
    return [string]$Item.LinkTarget -in @("private$name", "/private$name")
}

function Assert-ResearchPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $full = [IO.Path]::GetFullPath($Path)
    $boundary = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($full -ne $boundary -and -not $full.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'path_outside_root' }
    foreach ($part in ($full -split '[/\\]')) {
        if ($part -match '(?i)^(?:\.env(?:\..*)?|secrets?(?:\..*)?|credentials(?:\..*)?)$|\.(key|pem|pfx|p12)$') { throw 'secret_path_rejected' }
    }
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if ((($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -and -not (Test-ResearchMacSystemAlias -Item $item)) { throw 'reparse_point_rejected' }
        }
        $parent = [IO.Path]::GetDirectoryName($ancestor)
        if ($parent -eq $ancestor) { break }
        $ancestor = $parent
    }
    return $full
}

function Resolve-ResearchSourceRoot {
    param([string]$SourceRoot = '', $Context = $null, [string]$BaseRoot = (Get-Location).Path)
    $candidate = if ($SourceRoot) { $SourceRoot }
        elseif ($Context -and $Context.source_root) { [string]$Context.source_root }
        elseif ($env:CC_LWR_SOURCE_ROOT) { $env:CC_LWR_SOURCE_ROOT }
        else { Join-Path $HOME 'skill-source' }
    if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $BaseRoot $candidate }
    $full = Assert-ResearchPath -Path $candidate -Root $candidate
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw 'source_root_unavailable' }
    try { $null = Get-ChildItem -LiteralPath $full -ErrorAction Stop | Select-Object -First 1 }
    catch { throw 'source_root_unreadable' }
    return $full
}

function Resolve-ResearchInput {
    [CmdletBinding()]
    param([string]$ExplicitPath = '', [string]$JsonFile = '', [string]$WorkspaceRoot = (Get-Location).Path, [switch]$UseLastOutput, [string]$SourceRoot = '')
    $selected = $ExplicitPath
    $source = 'explicit'
    if (-not $selected -and ($JsonFile -or $UseLastOutput)) {
        $jsonPath = if ($JsonFile) { $JsonFile } else { Join-Path $WorkspaceRoot 'result/research/.last_research_output.json' }
        $jsonPath = Assert-ResearchPath -Path $jsonPath -Root $WorkspaceRoot
        try { $last = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable }
        catch { throw 'last_output_invalid' }
        if ($last['status'] -ne 'success' -or -not $last['path']) { throw 'last_output_failed' }
        $selected = $last.path; $source = 'json'
    }
    if (-not $selected) {
        $dir = Join-Path $WorkspaceRoot 'result/research'
        $candidates = @(if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Filter 'research_*Z*.md' -File | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object FullName })
        if ($candidates.Count -eq 0) { throw 'input_not_found' }
        return @{ status = 'selection_required'; candidates = @($candidates); reason_code = 'explicit_input_required' }
    }
    if (-not [IO.Path]::IsPathRooted($selected)) { $selected = Join-Path $WorkspaceRoot $selected }
    $path = Assert-ResearchPath -Path $selected -Root $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'input_not_found' }
    $contextPath = Get-ResearchContextPath -ReportPath $path
    $context = $null
    if (Test-Path -LiteralPath $contextPath) {
        $check = Test-ResearchContext -ContextPath $contextPath -ReportPath $path
        if (-not $check.Valid) { throw 'context_invalid' }
        $context = $check.Context
    }
    # Persisted last-output is eligible only when its report is hash-bound.
    if ($source -eq 'json' -and -not $context) { throw 'last_output_context_required' }
    $resolvedRoot = $null; $rootStatus = 'available'
    try { $resolvedRoot = Resolve-ResearchSourceRoot -SourceRoot $SourceRoot -Context $context -BaseRoot $WorkspaceRoot }
    catch { $rootStatus = 'unavailable' }
    return @{ status = 'resolved'; path = $path; source = $source; context = $context; source_root = $resolvedRoot; local_status = $rootStatus; original_query = if ($context) { $context.original_query } else { 'unknown' } }
}

Export-ModuleMember -Function @(
    'Get-ResearchFileSha256',
    'Get-ResearchContextPath',
    'New-ResearchContext',
    'Write-ResearchContext',
    'Test-ResearchContext',
    'Assert-ResearchSafeText',
    'Assert-ResearchPath',
    'Resolve-ResearchSourceRoot',
    'Resolve-ResearchInput'
)
