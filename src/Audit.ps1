# One row per timed delivery (schema 6): its tokens and the durations of its phases, those of its source invocations
# summed. Deliveries stored before durations were measured have no total and are left out. Incomparable counts the
# source invocations whose tokens are unknown or come from another tokenizer than the delivery's.
$script:OP2AuditSql = @'
SELECT d.id AS Id, d.timestamp AS Timestamp, COALESCE(d.route, MIN(i.label)) AS Route, MIN(i.label) AS Command, d.provider AS Provider,
d.tokens AS OutputTokens, SUM(i.tokens) AS SourceTokens, d.profile AS Profile, d.version AS Version, COUNT(i.id) AS Invocations, COUNT(i.process_ms) AS TimedInvocations,
SUM(CASE WHEN i.id IS NOT NULL AND (i.tokens IS NULL OR i.profile<>d.profile OR i.version<>d.version) THEN 1 ELSE 0 END) AS Incomparable,
d.total_ms AS TotalMs, d.recall_ms AS RecallMs, d.format_ms AS FormatMs, d.tokens_ms AS DeliveryTokensMs, d.storage_ms AS StorageMs,
d.import_ms AS ImportMs, SUM(i.process_ms) AS ProcessMs, SUM(i.backpressure_ms) AS BackpressureMs, SUM(i.callback_ms) AS CallbackMs,
SUM(i.setup_ms) AS SetupMs, SUM(i.complete_ms) AS CompleteMs, SUM(i.capture_ms) AS CaptureMs, SUM(i.tokens_ms) AS SourceTokensMs, SUM(i.records) AS Records
FROM deliveries d LEFT JOIN delivery_invocations x ON x.delivery=d.id LEFT JOIN invocations i ON i.id=x.invocation
WHERE d.total_ms IS NOT NULL AND (@since IS NULL OR d.timestamp >= @since)
GROUP BY d.id ORDER BY d.timestamp;
'@
# Timed native calls no delivery links to: the local objects (-AsObject) of scripts.
$script:OP2AuditLocalSql = @'
SELECT i.label AS Command, i.setup_ms AS SetupMs, i.process_ms AS ProcessMs, i.backpressure_ms AS BackpressureMs, i.callback_ms AS CallbackMs,
i.complete_ms AS CompleteMs, i.capture_ms AS CaptureMs, i.tokens_ms AS TokensMs, i.records AS Records
FROM invocations i
WHERE i.process_ms IS NOT NULL AND NOT EXISTS (SELECT 1 FROM delivery_invocations x WHERE x.invocation=i.id) AND (@since IS NULL OR i.timestamp >= @since)
ORDER BY i.timestamp;
'@
# The phases the overhead of a delivered call is made of, in report order. Callbacks run while the child runs: they
# are part of the overhead only through the waits they imposed on it (Backpressure).
$script:OP2AuditPhases = [ordered]@{ Setup = 'SetupMs'; Backpressure = 'BackpressureMs'; Complete = 'CompleteMs'; Capture = 'CaptureMs'
    Tokens = 'TokensMs'; Recall = 'RecallMs'; Format = 'FormatMs'; Storage = 'StorageMs' }

function Get-OP2Percentile {
    # The nearest-rank percentile of a list of numbers: the smallest value with at least Percent of the values at or
    # below it; nothing for an empty list.
    param([double[]]$Value, [double]$Percent)
    if (!$Value.Count) { return $null }
    $sorted = [double[]]($Value | Sort-Object)
    return $sorted[[Math]::Max(0, [int][Math]::Ceiling($Percent / 100 * $sorted.Count) - 1)]
}

function ConvertTo-OP2AuditNumber {
    # A stored duration or count, zero when it is unknown.
    param([object]$Value)
    if ($null -eq $Value) { return 0.0 }
    return [double]$Value
}

function ConvertTo-OP2AuditCall {
    # One delivery as the audit counts it: what pump added on top of the child (its overhead: the total without the
    # child's run, plus the waits a full queue imposed on it), its phases, and the tokens it saved. The saving is known
    # only when every count is, with the tokenizer of the report: otherwise it is null, never a negative guess.
    param([object]$Row, [string]$Tokenizer, [string]$Version)
    $known = ($null -ne $Row.OutputTokens -and $Row.Invocations -gt 0 -and !$Row.Incomparable -and $Row.Profile -eq $Tokenizer -and $Row.Version -eq $Version)
    [pscustomobject][ordered]@{ Route = $Row.Route; Command = $Row.Command; Provider = $Row.Provider
        SavedTokens = $(if ($known) { [double]$Row.SourceTokens - [double]$Row.OutputTokens } else { $null })
        # Zero invocations means no child. A linked invocation without a duration is unknown, never a zero-length child.
        OverheadMs = $(if ($Row.TimedInvocations -eq $Row.Invocations) {
            (ConvertTo-OP2AuditNumber $Row.TotalMs) - (ConvertTo-OP2AuditNumber $Row.ProcessMs) + (ConvertTo-OP2AuditNumber $Row.BackpressureMs)
        } else { $null })
        BackpressureMs = ConvertTo-OP2AuditNumber $Row.BackpressureMs; Records = ConvertTo-OP2AuditNumber $Row.Records
        CallbackMs = ConvertTo-OP2AuditNumber $Row.CallbackMs; SetupMs = ConvertTo-OP2AuditNumber $Row.SetupMs
        CompleteMs = ConvertTo-OP2AuditNumber $Row.CompleteMs; CaptureMs = ConvertTo-OP2AuditNumber $Row.CaptureMs
        TokensMs = (ConvertTo-OP2AuditNumber $Row.SourceTokensMs) + (ConvertTo-OP2AuditNumber $Row.DeliveryTokensMs)
        RecallMs = ConvertTo-OP2AuditNumber $Row.RecallMs; FormatMs = ConvertTo-OP2AuditNumber $Row.FormatMs
        StorageMs = ConvertTo-OP2AuditNumber $Row.StorageMs; ImportMs = ConvertTo-OP2AuditNumber $Row.ImportMs }
}

function ConvertTo-OP2AuditLocalCall {
    # A local call (-AsObject) as the audit counts it: no delivery, so no total and no saving; its overhead is the sum
    # of its measured phases, the waits on its queue included.
    param([object]$Row)
    $call = [ordered]@{ Command = $Row.Command; Records = ConvertTo-OP2AuditNumber $Row.Records; CallbackMs = ConvertTo-OP2AuditNumber $Row.CallbackMs
        BackpressureMs = ConvertTo-OP2AuditNumber $Row.BackpressureMs; OverheadMs = 0.0 }
    foreach ($name in @('SetupMs', 'BackpressureMs', 'CompleteMs', 'CaptureMs', 'TokensMs')) { $call.OverheadMs += ConvertTo-OP2AuditNumber $Row.$name }
    [pscustomobject]$call
}

function Get-OP2AuditSum {
    # The sum of one property over calls, unknown values left out; zero for none, where Measure-Object returns nothing.
    param([object[]]$Call, [string]$Property)
    $sum = 0.0
    foreach ($item in $Call) { if ($null -ne $item.$Property) { $sum += $item.$Property } }
    return $sum
}

function Measure-OP2AuditGroup {
    # The audit line of a group of calls: runs, those whose saving is unknown, tokens saved, overhead (total, p50,
    # p95), callback time per thousand lines, backpressure, tokens saved per second of the overhead of the calls whose
    # saving is known, and their value at the configured price per million tokens.
    param([string]$Key, [object[]]$Call, [object]$TokenPrice)
    $timed = @($Call | Where-Object { $null -ne $_.OverheadMs })
    $overhead = [double[]]@($timed | ForEach-Object OverheadMs)
    $measured = @($Call | Where-Object { $null -ne $_.PSObject.Properties['SavedTokens'] -and $null -ne $_.SavedTokens })
    $saved = Get-OP2AuditSum $measured SavedTokens
    $rated = @($measured | Where-Object { $null -ne $_.OverheadMs })
    $measuredOverhead = Get-OP2AuditSum $rated OverheadMs
    $records = Get-OP2AuditSum $Call Records
    [ordered]@{ Key = $Key; Runs = $Call.Count; UnknownTokens = $Call.Count - $measured.Count; UnknownDurations = $Call.Count - $timed.Count; SavedTokens = $saved
        OverheadMs = Get-OP2AuditSum $Call OverheadMs; P50Ms = Get-OP2Percentile $overhead 50; P95Ms = Get-OP2Percentile $overhead 95
        CallbackMsPer1kLines = $(if ($records) { (Get-OP2AuditSum $Call CallbackMs) / $records * 1000 } else { $null })
        BackpressureMs = Get-OP2AuditSum $Call BackpressureMs
        TokensPerOverheadSecond = $(if ($measuredOverhead -gt 0) { (Get-OP2AuditSum $rated SavedTokens) / ($measuredOverhead / 1000) } else { $null })
        SavedValue = $(if ($null -ne $TokenPrice) { $saved * [double]$TokenPrice / 1e6 } else { $null }) }
}

function Get-OP2AuditPhase {
    # Where the overhead of delivered calls went, phase by phase, as shares of that overhead; Other is what no phase
    # measured before the delivery write (for example dispatch around callbacks). The delivery write is outside total.
    param([object[]]$Call)
    $Call = @($Call | Where-Object { $null -ne $_.OverheadMs })
    $overhead = Get-OP2AuditSum $Call OverheadMs
    $phases = [ordered]@{}
    $named = 0.0
    foreach ($phase in $script:OP2AuditPhases.Keys) {
        $spent = Get-OP2AuditSum $Call $script:OP2AuditPhases[$phase]
        $named += $spent
        $phases[$phase] = $(if ($overhead -gt 0) { $spent / $overhead * 100 } else { 0.0 })
    }
    $phases.Other = $(if ($overhead -gt 0) { [Math]::Max(0.0, $overhead - $named) / $overhead * 100 } else { 0.0 })
    return $phases
}

function ConvertTo-OP2AuditMarkdown {
    # The audit as a Markdown page: totals, one table row per group, the phases of the overhead, and the local calls.
    param([Collections.IDictionary]$Audit)
    $number = { param($value, $digits) $(if ($null -eq $value) { '' } else { [Math]::Round([double]$value, $digits).ToString("N$digits", [Globalization.CultureInfo]::InvariantCulture) }) }
    $page = [Text.StringBuilder]::new()
    [void]$page.AppendLine("# OPumper2 audit$(if ($Audit.Since) { " since $($Audit.Since)" })").AppendLine()
    $totals = $Audit.Total
    $value = $(if ($null -ne $totals['SavedValue']) { " Value saved: $(& $number $totals.SavedValue 2) $($Audit['Currency'])." })
    [void]$page.AppendLine("$($totals.Runs) runs ($($totals.UnknownTokens) without known tokens), $(& $number $totals.SavedTokens 0) tokens saved, $(& $number ($totals.OverheadMs / 1000) 1) s of overhead: $(& $number $totals.TokensPerOverheadSecond 0) tokens saved per second of overhead.$value Module import: $(& $number ($Audit['ImportMs'] / 1000) 1) s.").AppendLine()
    if ($totals['UnknownDurations']) { [void]$page.AppendLine("$($totals['UnknownDurations']) runs have unknown process durations; overhead statistics exclude them.").AppendLine() }
    [void]$page.AppendLine("| $($Audit.GroupBy) | Runs | Unknown tokens | Tokens saved | Overhead (s) | p50 (ms) | p95 (ms) | Callbacks (ms / 1k lines) | Backpressure (ms) | Tokens / s |")
    [void]$page.AppendLine('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    foreach ($group in $Audit.Groups) {
        [void]$page.AppendLine("| $($group.Key) | $($group.Runs) | $($group.UnknownTokens) | $(& $number $group.SavedTokens 0) | $(& $number ($group.OverheadMs / 1000) 1) | $(& $number $group.P50Ms 0) | $(& $number $group.P95Ms 0) | $(& $number $group.CallbackMsPer1kLines 1) | $(& $number $group.BackpressureMs 0) | $(& $number $group.TokensPerOverheadSecond 0) |")
    }
    [void]$page.AppendLine().Append('Overhead by phase: ').AppendLine((@($Audit.Phases.GetEnumerator() | ForEach-Object { "$($_.Key) $(& $number $_.Value 0) %" }) -join ', '))
    if ($Audit['Local']) {
        [void]$page.AppendLine().AppendLine('Local calls (-AsObject, no delivery):').AppendLine()
        [void]$page.AppendLine('| Command | Runs | Overhead (s) | p50 (ms) | p95 (ms) | Callbacks (ms / 1k lines) |').AppendLine('|---|---:|---:|---:|---:|---:|')
        foreach ($group in $Audit.Local) {
            [void]$page.AppendLine("| $($group.Key) | $($group.Runs) | $(& $number ($group.OverheadMs / 1000) 1) | $(& $number $group.P50Ms 0) | $(& $number $group.P95Ms 0) | $(& $number $group.CallbackMsPer1kLines 1) |")
        }
    }
    return $page.ToString()
}

function Get-OPumper2Audit {
    # What pump cost in time against what it saved in tokens, from the measurement history: per route, command or
    # provider, by phase of the overhead, and the local calls apart. Only calls whose durations were measured count;
    # tokens count only when known and from the configured tokenizer. AsMarkdown renders a page; the other switches
    # deliver the report as any report.
    [CmdletBinding()]
    param([Nullable[datetime]]$Since, [ValidateSet('Route', 'Command', 'Provider')][string]$GroupBy = 'Route',
        [switch]$AsMarkdown, [switch]$AsObject, [switch]$AsJson, [switch]$AsYaml)
    $configuration = Get-OP2Configuration
    Initialize-OP2Dependency
    $version = $script:OP2Tokenizers[$configuration.Tokenizer].Version
    # A name of its own: $since would be $Since, typed DateTime, which would convert the text back.
    $sinceText = $(if ($null -ne $Since) { $Since.ToUniversalTime().ToString('O') } else { $null })
    $rows = @(Invoke-OP2Sql -Configuration $configuration -Read -Sql $script:OP2AuditSql -Parameters @{ since = $sinceText })
    $calls = @($rows | ForEach-Object { ConvertTo-OP2AuditCall $_ $configuration.Tokenizer $version })
    $groups = @($calls | Group-Object { $(if ($_.$GroupBy) { $_.$GroupBy } else { '(direct)' }) } | ForEach-Object { Measure-OP2AuditGroup $_.Name @($_.Group) $configuration.TokenPrice } |
        Sort-Object @{ Expression = { $_.SavedTokens }; Descending = $true }, Key)
    $local = @(@(Invoke-OP2Sql -Configuration $configuration -Read -Sql $script:OP2AuditLocalSql -Parameters @{ since = $sinceText }) | ForEach-Object { ConvertTo-OP2AuditLocalCall $_ } |
        Group-Object Command | ForEach-Object { Measure-OP2AuditGroup $_.Name @($_.Group) $null } | Sort-Object @{ Expression = { $_.OverheadMs }; Descending = $true }, Key)
    $audit = [ordered]@{ Since = $sinceText; GroupBy = $GroupBy; Currency = $configuration.Currency; Total = Measure-OP2AuditGroup 'Total' $calls $configuration.TokenPrice
        ImportMs = Get-OP2AuditSum $calls ImportMs; Groups = $groups; Phases = Get-OP2AuditPhase $calls; Local = $local }
    if ($AsMarkdown) { return ConvertTo-OP2AuditMarkdown $audit }
    Format-OPumper2Report (New-OPumper2Result -Data $audit) $PSBoundParameters
}
