Set-StrictMode -Version Latest

function Get-DdUtc { [DateTimeOffset]::UtcNow }

function ConvertFrom-DdJson {
    param([string]$Json)
    # System.Text.Json preserves ISO strings on PowerShell 7.4 as well as 7.5.
    function Convert-Node($Node) {
        switch ($Node.ValueKind.ToString()) {
            Object { $result = @{}; foreach ($property in $Node.EnumerateObject()) { $result[$property.Name] = Convert-Node $property.Value }; return $result }
            Array { $items = @(foreach ($item in $Node.EnumerateArray()) { Convert-Node $item }); return ,$items }
            String { return $Node.GetString() }
            Number { $integer = 0L; if ($Node.TryGetInt64([ref]$integer)) { return $integer }; return $Node.GetDouble() }
            True { return $true }
            False { return $false }
            Null { return $null }
        }
    }
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try { return Convert-Node $document.RootElement } finally { $document.Dispose() }
}

function Get-DdHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'file_unavailable' }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-DdSchema {
    param($Value, [string]$Definition = '')
    $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../references/research-state.schema.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($Definition) { $schema = @{ '$schema' = $schema.'$schema'; '$defs' = $schema.'$defs'; '$ref' = "#/`$defs/$Definition" } }
    $json = ConvertTo-Json -InputObject $Value -Depth 40
    if (-not (Test-Json -Json $json -Schema ($schema | ConvertTo-Json -Depth 50) -ErrorAction SilentlyContinue)) { throw 'state_schema_invalid' }
    Assert-ResearchSafeText -Text $json
}

function Save-DdState {
    param($State, [string]$Path)
    Assert-DdSchema $State
    $tmp = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $State -Depth 40), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tmp, $Path, $true)
    } catch { throw 'state_write_failed' }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

function Read-DdState {
    param([string]$Path, [string]$RunId)
    try { $state = ConvertFrom-DdJson (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) }
    catch { throw 'state_unavailable' }
    Assert-DdSchema $state
    if ($state.run_id -ne $RunId) { throw 'run_id_mismatch' }
    return $state
}

function Update-DdClock {
    param($State, [DateTimeOffset]$Now)
    if ($State.status -eq 'active' -and $State.budget.active_since) {
        $State.budget.elapsed_seconds = [double]$State.budget.elapsed_seconds + [Math]::Max([double]0, ($Now - [DateTimeOffset]::Parse($State.budget.active_since)).TotalSeconds)
        $State.budget.active_since = $Now.ToString('o')
    }
}

function Get-DdCutoff {
    param($State)
    if ($State.budget.elapsed_seconds -ge $State.config.max_minutes * 60) { return 'time_budget' }
    if ($State.budget.web_operations -ge $State.config.max_web_operations) { return 'web_budget' }
    return $null
}

function Get-DdSourceFingerprint {
    param([string]$Root)
    if (-not $Root) { return $null }
    Assert-ResearchPath -Path $Root -Root $Root | Out-Null
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'source_root_unavailable' }
    $entries = [Collections.Generic.List[string]]::new()
    try { $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Stop) }
    catch { throw 'source_root_unreadable' }
    foreach ($file in $files | Sort-Object FullName) {
        $rel = [IO.Path]::GetRelativePath($Root, $file.FullName) -replace '\\', '/'
        if ($file.Extension -notin @('.md', '.txt', '.json', '.csv', '.yaml', '.yml') -or $rel -match '(^|/)\.' -or $file.Name -like '*.meta.yaml' -or $file.Name -like '*.tmp.*.json') { continue }
        try { Assert-ResearchPath -Path $file.FullName -Root $Root | Out-Null }
        catch { $entries.Add("$rel|excluded"); continue }
        try { $entries.Add("$rel|$(Get-DdHash $file.FullName)") }
        catch { $entries.Add("$rel|unreadable") }
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))).ToLowerInvariant()
}

function Test-DdEvidenceCurrent {
    param($Evidence, $State)
    if ($Evidence.kind -eq 'web') { return ($Evidence.verified -and $Evidence.retrieval_status -eq 'body') }
    if (-not $State.source_root) { return $false }
    try {
        $path = Assert-ResearchPath -Path $Evidence.path -Root $State.source_root
        if ((Get-DdHash $path) -ne $Evidence.sha256) { return $false }
        $lines = @(Get-Content -LiteralPath $path -Encoding utf8 -ErrorAction Stop)
        if ($Evidence.line_start -lt 1 -or $Evidence.line_end -lt $Evidence.line_start -or $Evidence.line_end -gt $lines.Count) { return $false }
        $readText = $lines[($Evidence.line_start - 1)..($Evidence.line_end - 1)] -join "`n"
        if (-not $readText.Contains(($Evidence.excerpt -replace "`r`n", "`n"), [StringComparison]::Ordinal)) { return $false }
        return ($Evidence.verified -and $Evidence.retrieval_status -eq 'body')
    } catch { return $false }
}

function Reset-DdStaleEvidence {
    param($State)
    foreach ($evidence in $State.evidence) {
        if ($evidence.verified -and -not (Test-DdEvidenceCurrent $evidence $State)) {
            $evidence.verified = $false
            foreach ($issue in $State.issues | Where-Object { $_.id -in $evidence.issue_ids }) {
                $issue.status = 'unverified'; $issue.closing_reason = 'source_changed'
            }
        }
    }
}

function Assert-DdComplete {
    param($State, [string]$ReportPath, [string]$ReportHash)
    if ($State.issues.Count -eq 0 -or (Get-DdCutoff $State) -or $State.budget.cutoff_reason -or $State.budget.interruption_unmeasured) { throw 'complete_not_allowed' }
    if (@($State.actions | Where-Object { $_.status -in @('planned', 'started') }).Count) { throw 'actions_pending' }
    foreach ($issue in $State.issues) {
        if ($issue.required -or $issue.severity -in @('critical', 'p1')) {
            if ($issue.status -ne 'resolved' -or -not $issue.closing_reason -or -not $issue.coverage_notes) { throw 'required_issue_unresolved' }
            if ($issue.answer_kind -eq 'supported' -and $issue.evidence_ids.Count -eq 0) { throw 'evidence_required' }
            if (@($State.actions | Where-Object { $_.issue_id -eq $issue.id -and $_.status -in @('failed', 'interrupted') }).Count) { throw 'retrieval_unresolved' }
            if (-not @($State.actions | Where-Object { $_.issue_id -eq $issue.id -and $_.status -in @('succeeded', 'empty') }).Count) { throw 'search_required' }
        }
        foreach ($id in $issue.evidence_ids) {
            $entry = @($State.evidence | Where-Object id -EQ $id)
            if ($entry.Count -ne 1 -or $issue.id -notin $entry[0].issue_ids -or -not (Test-DdEvidenceCurrent $entry[0] $State)) { throw 'evidence_unverified' }
        }
    }
    if (-not $State.review -or $State.review.report_sha256 -ne $ReportHash -or $State.review.major_findings -ne 0) { throw 'review_required' }
    foreach ($key in @('semantic_checked', 'citations_checked', 'contradictions_checked', 'scope_checked')) { if (-not $State.review[$key]) { throw 'review_incomplete' } }
    foreach ($issue in $State.issues) { if ($issue.id -notin $State.review.checked_issue_ids) { throw 'review_incomplete' } }
    $content = Get-Content -LiteralPath $ReportPath -Raw -Encoding utf8
    foreach ($heading in @('再調査後の回答', '前回からの変更', '検索範囲と制限', '未解決事項', '出典')) {
        if ($content -notmatch "(?m)^##\s+$heading\s*$") { throw 'report_structure_invalid' }
    }
    $cited = @([regex]::Matches($content, '\[((?:DD|ORIG)-(?:L|W|DL)\d+)\]') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    foreach ($issue in $State.issues) { foreach ($id in $issue.evidence_ids) { if ($id -notin $cited) { throw 'report_citation_missing' } } }
    foreach ($id in $cited) {
        $entry = @($State.evidence | Where-Object id -EQ $id)
        if ($entry.Count -ne 1 -or $id -notin $State.review.checked_evidence_ids -or -not (Test-DdEvidenceCurrent $entry[0] $State)) { throw 'report_citation_unverified' }
    }
}

function Invoke-DeepDiveStateCommand {
    [CmdletBinding()]
    param([hashtable]$Options)
    $o = $Options
    Import-Module (Join-Path $PSScriptRoot 'DeepDiveResearch.psm1') -ErrorAction Stop
    $deps = Resolve-SkillDependencies
    if ($deps.Errors.Count) { throw 'dependency_unresolved' }
    $sibling = Split-Path (Split-Path $deps.Paths.DD_COLLECT_SKILL_SOURCE_PATH -Parent) -Parent
    Import-Module (Join-Path $sibling 'scripts/ResearchContext.psm1') -ErrorAction Stop
    $workspace = [IO.Path]::GetFullPath($o.WorkspaceRoot)
    $base = if ($o.StateRoot) { $o.StateRoot } else { Join-Path $workspace 'result/deepdive/.run-state' }
    $runDir = Assert-ResearchPath -Path (Join-Path $base $o.RunId) -Root $workspace
    $statePath = Assert-ResearchPath -Path (Join-Path $runDir 'state.json') -Root $workspace
    $lockPath = Assert-ResearchPath -Path (Join-Path $runDir 'state.lock') -Root $workspace
    if ($o.Operation -eq 'read') {
        $state = Read-DdState $statePath $o.RunId
        return @{ status = 'ok'; state_path = $statePath; revision = $state.revision; state = $state }
    }
    if ($o.Operation -ne 'init' -and -not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'state_unavailable' }
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $lock = $null
    try {
        try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') } catch { throw 'state_busy' }
        # Keep the inode after closing: unlinking the lock introduces a race on Unix.
        $now = Get-DdUtc
        $reason = $null
        if ($o.Operation -eq 'init') {
            if (Test-Path -LiteralPath $statePath) { throw 'state_already_exists' }
            $parent = Assert-ResearchPath -Path $o.ParentInputPath -Root $workspace
            $ctxPath = Get-ResearchContextPath -ReportPath $parent
            $ctx = $null
            if (Test-Path -LiteralPath $ctxPath) {
                $check = Test-ResearchContext -ContextPath $ctxPath -ReportPath $parent
                if (-not $check.Valid) { throw 'context_invalid' }
                $ctx = $check.Context
            }
            $source = $null; $sourceStatus = 'available'
            try { $source = Resolve-ResearchSourceRoot -SourceRoot $o.SourceRoot -Context $ctx -BaseRoot $workspace }
            catch { $sourceStatus = 'unavailable' }
            $state = @{
                schema_version = '1.1'; run_id = $o.RunId; status = 'active'; revision = 0
                created_at = $now.ToString('o'); updated_at = $now.ToString('o')
                parent_input = @{ path = $parent; sha256 = Get-DdHash $parent }
                original_query = if ($o.OriginalQuery) { $o.OriginalQuery } elseif ($ctx) { $ctx.original_query } else { 'unknown' }
                source_root = $source; source_status = $sourceStatus; source_fingerprint = Get-DdSourceFingerprint $source
                config = @{ max_minutes = $o.MaxMinutes; max_web_operations = $o.MaxWebOperations }
                budget = @{ elapsed_seconds = 0.0; web_operations = 0; active_since = $now.ToString('o'); cutoff_reason = $null; interruption_unmeasured = $false }
                actions = @(); issues = @(); evidence = @(); routes = @{}; history = @()
                review = $null; output = $null; pending_output = $null; previous_outputs = @(); error = $null
            }
        } else {
            $state = Read-DdState $statePath $o.RunId
            if ($o.ExpectedRevision -lt 0 -or $state.revision -ne $o.ExpectedRevision) { throw 'revision_conflict' }
            if ($state.status -eq 'complete') {
                if ($o.Operation -eq 'finalize' -and $o.OutputPath -eq $state.output.path -and (Get-DdHash $o.OutputPath) -eq $state.output.sha256 -and $o.RunStatus -eq 'complete') { return @{ status = 'ok'; revision = $state.revision; state_path = $statePath; state = $state } }
                throw 'run_complete_start_new'
            }
            $payload = if ($o.PayloadJson) { try { ConvertFrom-DdJson $o.PayloadJson } catch { throw 'payload_invalid' } } else { @{} }
            Assert-ResearchSafeText -Text ($payload | ConvertTo-Json -Depth 30)
            if ($o.Operation -ne 'resume') { Update-DdClock $state $now }
            $finishingAction = $o.Operation -eq 'action' -and $o.ActionStatus -in @('succeeded', 'empty', 'failed', 'interrupted') -and @($state.actions | Where-Object { $_.id -eq $o.ActionId -and $_.status -eq 'started' }).Count -eq 1
            if ($o.Operation -notin @('resume', 'finalize') -and $state.status -ne 'active' -and -not $finishingAction) { throw 'resume_required' }
            switch ($o.Operation) {
                'resume' {
                    if ((Get-DdHash (Assert-ResearchPath -Path $state.parent_input.path -Root $workspace)) -ne $state.parent_input.sha256) { throw 'parent_input_changed_start_new' }
                    foreach ($output in @($state.previous_outputs) + @($state.output) + @($state.pending_output)) {
                        if ($output -and (Get-DdHash (Assert-ResearchPath -Path $output.path -Root $workspace)) -ne $output.sha256) { throw 'output_hash_mismatch' }
                    }
                    if ($state.pending_output) {
                        $state.previous_outputs += $state.pending_output; $state.pending_output = $null
                        $state.history += @{ event = 'uncommitted_output_preserved'; at = $now.ToString('o') }
                    }
                    if ($state.status -eq 'active') { $state.budget.interruption_unmeasured = $true }
                    foreach ($action in $state.actions | Where-Object status -EQ 'started') {
                        $action.status = 'interrupted'; $action.attempts[-1].status = 'interrupted'
                        $action.attempts[-1].ended_at = $now.ToString('o'); $action.attempts[-1].reason_code = 'resume_interrupted'
                    }
                    if ($payload.ContainsKey('interrupted_seconds')) {
                        if ($payload.interrupted_seconds -isnot [ValueType] -or $payload.interrupted_seconds -lt 0 -or -not $payload['reason']) { throw 'resume_budget_invalid' }
                        $state.budget.elapsed_seconds += $payload.interrupted_seconds; $state.budget.interruption_unmeasured = $false
                    }
                    foreach ($key in @('max_minutes', 'max_web_operations')) {
                        if ($payload.ContainsKey($key)) {
                            if ($payload[$key] -isnot [ValueType] -or $payload[$key] -lt $state.config[$key] -or -not $payload['reason']) { throw 'resume_budget_invalid' }
                            $state.config[$key] = $payload[$key]
                        }
                    }
                    if ($o.SourceRoot) { $state.source_root = Resolve-ResearchSourceRoot -SourceRoot $o.SourceRoot -BaseRoot $workspace; $state.source_status = 'available' }
                    try { $fingerprint = Get-DdSourceFingerprint $state.source_root }
                    catch { $fingerprint = $null; $state.source_status = 'unavailable' }
                    Reset-DdStaleEvidence $state
                    if ($fingerprint -ne $state.source_fingerprint) { foreach ($issue in $state.issues) { $issue.status = 'unverified'; $issue.closing_reason = 'corpus_changed' } }
                    $state.source_fingerprint = $fingerprint; $state.review = $null
                    $state.budget.cutoff_reason = Get-DdCutoff $state
                    if ($state.budget.cutoff_reason) { throw 'resume_budget_required' }
                    $state.status = 'active'; $state.budget.active_since = $now.ToString('o')
                    $state.history += @{ event = 'resume'; at = $now.ToString('o'); budget = $payload }
                }
                'issue' {
                    try { $issue = ConvertFrom-DdJson $o.IssueJson } catch { throw 'issue_invalid' }
                    $issue.id = $o.IssueId
                    Assert-DdSchema $issue 'issue'
                    $state.issues = @($state.issues | Where-Object id -NE $o.IssueId) + @($issue); $state.review = $null
                }
                'evidence' {
                    try { $evidence = ConvertFrom-DdJson $o.EvidenceJson } catch { throw 'evidence_invalid' }
                    Assert-DdSchema $evidence 'evidence'
                    foreach ($id in $evidence.issue_ids) { if ($id -notin @($state.issues | ForEach-Object id)) { throw 'issue_not_found' } }
                    if ($evidence.verified -and -not (Test-DdEvidenceCurrent $evidence $state)) { throw 'evidence_unverified' }
                    $state.evidence = @($state.evidence | Where-Object id -NE $evidence.id) + @($evidence); $state.review = $null
                }
                'route' {
                    if (-not $payload['route'] -or -not $payload['reason']) { throw 'route_assessment_required' }
                    $state.routes[$payload.route] = 0
                    $state.history += @{ event = 'route_assessed'; at = $now.ToString('o'); route = $payload.route; reason = $payload.reason }; $state.review = $null
                }
                'action' {
                    $state.review = $null
                    $existing = @($state.actions | Where-Object id -EQ $o.ActionId)
                    if ($existing.Count -eq 0) {
                        if ($o.ActionStatus -ne 'planned') { throw 'action_transition_invalid' }
                        $action = @{ id = $o.ActionId; type = $o.ActionType; issue_id = $o.IssueId; route = $payload['route']; query = $payload['query']; public_query_approved = ($payload['public_query_approved'] -eq $true); status = 'planned'; attempts = @(); result = $null }
                        Assert-DdSchema $action 'action'
                        if ($o.IssueId -notin @($state.issues | ForEach-Object id)) { throw 'issue_not_found' }
                        if ($o.ActionType -in @('web-search', 'web-fetch') -and -not $action.public_query_approved) { throw 'public_query_approval_required' }
                        $state.actions += $action
                    } else {
                        $action = $existing[0]
                        if ($o.ActionType -and $action.type -ne $o.ActionType) { throw 'action_identity_changed' }
                        if ($o.ActionStatus -eq 'planned') {
                            if ($action.status -notin @('failed', 'interrupted') -or $action.attempts.Count -ge 3) { throw 'retry_limit' }
                            $action.status = 'planned'
                        } elseif ($o.ActionStatus -eq 'started') {
                            if ($action.status -ne 'planned') { throw 'action_transition_invalid' }
                            if ($state.routes.ContainsKey($action.route) -and $state.routes[$action.route] -ge 5) { throw 'route_paused' }
                            $cutoff = Get-DdCutoff $state
                            if ($cutoff) { $reason = $cutoff; break }
                            if ($action.type -in @('web-search', 'web-fetch')) { $state.budget.web_operations++ }
                            $action.status = 'started'
                            $action.attempts += @{ status = 'started'; started_at = $now.ToString('o'); ended_at = $null; reason_code = $null }
                        } else {
                            if ($action.status -ne 'started') { throw 'action_transition_invalid' }
                            Assert-DdSchema $payload 'actionResult'
                            $action.status = $o.ActionStatus; $action.attempts[-1].status = $o.ActionStatus
                            $action.attempts[-1].ended_at = $now.ToString('o'); $action.attempts[-1].reason_code = $payload.reason_code
                            $action.result = $payload
                            if ($o.ActionStatus -in @('failed', 'interrupted')) {
                                if (-not $state.routes.ContainsKey($action.route)) { $state.routes[$action.route] = 0 }
                                $state.routes[$action.route]++
                            } else { $state.routes[$action.route] = 0 }
                        }
                    }
                }
                'checkpoint' {
                    if ($o.RunStatus -notin @('partial', 'cancelled', 'failed')) { throw 'checkpoint_status_invalid' }
                    if ($payload.ContainsKey('budget')) { throw 'budget_readonly' }
                    $state.status = $o.RunStatus; $state.budget.active_since = $null; $state.review = $null
                    $state.budget.cutoff_reason = Get-DdCutoff $state
                }
                'review' {
                    Assert-DdSchema $payload 'review'
                    $path = Assert-ResearchPath -Path $o.OutputPath -Root $workspace
                    if ((Get-DdHash $path) -ne $payload.report_sha256) { throw 'review_hash_mismatch' }
                    Reset-DdStaleEvidence $state; $state.review = $payload
                }
                'finalize' {
                    if ($o.RunStatus -notin @('complete', 'partial', 'cancelled', 'failed')) { throw 'final_status_invalid' }
                    $path = Assert-ResearchPath -Path $o.OutputPath -Root $workspace
                    $hash = Get-DdHash $path
                    Assert-ResearchSafeText -Text (Get-Content -LiteralPath $path -Raw)
                    if ($o.OutputSha256 -and $hash -ne $o.OutputSha256) { throw 'output_hash_mismatch' }
                    foreach ($prior in @($state.previous_outputs) + @($state.output) + @($state.pending_output)) { if ($prior -and $prior.path -eq $path) { throw 'output_already_finalized' } }
                    if ($o.RunStatus -eq 'complete') {
                        if ($state.source_status -ne 'available') { throw 'source_root_unavailable' }
                        if ((Get-DdSourceFingerprint $state.source_root) -ne $state.source_fingerprint) { throw 'corpus_changed_resume_required' }
                        Assert-DdComplete $state $path $hash
                    }
                    $output = @{ path = $path; sha256 = $hash; finalized_at = $now.ToString('o'); status = $o.RunStatus }
                    $state.pending_output = $output; $state.status = 'partial'; $state.budget.active_since = $null
                    $state.revision++; $state.updated_at = $now.ToString('o')
                    Save-DdState $state $statePath
                    $context = New-ResearchContext -ReportPath $path -RunId $o.RunId -OriginalQuery $state.original_query -SourceRoot $state.source_root
                    $context.report_type = 'deepdive'; $context.state_path = $statePath
                    $context.parent_report_path = $state.parent_input.path; $context.parent_report_sha256 = $state.parent_input.sha256
                    Write-ResearchContext -Context $context | Out-Null
                    if ((Get-DdHash $path) -ne $hash) { throw 'output_hash_mismatch' }
                    if ($state.output) { $state.previous_outputs += $state.output }
                    $state.output = $output; $state.pending_output = $null; $state.status = $o.RunStatus
                }
                default { throw 'operation_invalid' }
            }
            $state.revision++; $state.updated_at = $now.ToString('o')
            $cutoff = Get-DdCutoff $state
            if ($reason -or ($cutoff -and $state.status -eq 'active' -and -not @($state.actions | Where-Object status -EQ 'started').Count)) {
                $state.budget.cutoff_reason = $cutoff; $state.status = 'partial'; $state.budget.active_since = $null
            }
        }
        Save-DdState $state $statePath
        return @{ status = if ($reason) { 'error' } else { 'ok' }; reason_code = $reason; revision = $state.revision; state_path = $statePath; state = $state }
    } finally { if ($lock) { $lock.Dispose() } }
}

Export-ModuleMember -Function Invoke-DeepDiveStateCommand, Get-DdSourceFingerprint
