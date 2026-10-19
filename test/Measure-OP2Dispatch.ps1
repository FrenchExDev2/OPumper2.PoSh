#requires -Version 7.6
# Measures what handing records to callbacks costs, per thousand records, for the ways a batch can be dispatched:
# the record callback behind one diagnostic check per record (the current dispatch), one check per batch, no check at
# all (the lower bound), and a batch callback that loops itself. The callback is the Git status contract's parser, the
# heaviest contract the audit measured. Prints one JSON line.
[CmdletBinding()]
param([int]$Records = 20000, [int[]]$BatchSize = @(8, 64, 512), [int]$Repeat = 3)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path (Split-Path $root) 'FrenchExDev.OPumper2.Git.PoSh/src/GitStatus.Contract.ps1')

function New-BenchState {
    [pscustomobject]@{ LocalBranch = $null; HeadOid = $null; Unborn = $null; Upstream = $null; UpstreamAhead = $null; UpstreamBehind = $null
        PendingOriginal = $false; ErrorFrames = 0
        Counts = @{ Added = 0L; Modified = 0L; Deleted = 0L; Untracked = 0L; Renamed = 0L; Copied = 0L; Conflicted = 0L; TypeChanged = 0L; Staged = 0L; Unstaged = 0L; TotalChangedPaths = 0L } }
}

# The current dispatch: one diagnostic check per record.
function Invoke-PerRecord {
    param([object[]]$Batch, [scriptblock]$Callback, [object]$State)
    foreach ($record in $Batch) {
        & $Callback $record $State *>&1 | & { process {
            if ($_ -is [Management.Automation.ErrorRecord] -or $_ -is [Management.Automation.InformationalRecord] -or $_ -is [Management.Automation.InformationRecord]) { throw 'diagnostic' }
            ,$_ } }
    }
}
# One diagnostic check around the whole batch.
function Invoke-PerBatch {
    param([object[]]$Batch, [scriptblock]$Callback, [object]$State)
    & { foreach ($record in $Batch) { & $Callback $record $State } } *>&1 | & { process {
        if ($_ -is [Management.Automation.ErrorRecord] -or $_ -is [Management.Automation.InformationalRecord] -or $_ -is [Management.Automation.InformationRecord]) { throw 'diagnostic' }
        ,$_ } }
}
# No check: the floor of any dispatch through a callback.
function Invoke-Unchecked {
    param([object[]]$Batch, [scriptblock]$Callback, [object]$State)
    foreach ($record in $Batch) { & $Callback $record $State }
}
# A batch callback: one call per batch, the loop inside the contract.
function Invoke-BatchCallback {
    param([object[]]$Batch, [scriptblock]$Callback, [object]$State)
    & $Callback $Batch $State *>&1 | & { process {
        if ($_ -is [Management.Automation.ErrorRecord] -or $_ -is [Management.Automation.InformationalRecord] -or $_ -is [Management.Automation.InformationRecord]) { throw 'diagnostic' }
        ,$_ } }
}

$all = [object[]]::new($Records)
for ($i = 0; $i -lt $Records; $i++) {
    $all[$i] = [pscustomobject]@{ Stream = 'stdout'; Text = "1 .M N... 100644 100644 100644 0123456789abcdef 0123456789abcdef src/folder/file$i.cs"; Sequence = $i }
}
$parse = Get-Command Read-GitStatusBatch -CommandType Function
$onRecord = { param($record, $localState) & $parse @($record) $localState }.GetNewClosure()
$onBatch = { param($batch, $localState) & $parse $batch $localState }.GetNewClosure()
$variants = [ordered]@{
    PerRecord = @{ Dispatch = 'Invoke-PerRecord'; Callback = $onRecord }
    PerBatch = @{ Dispatch = 'Invoke-PerBatch'; Callback = $onRecord }
    Unchecked = @{ Dispatch = 'Invoke-Unchecked'; Callback = $onRecord }
    BatchCallback = @{ Dispatch = 'Invoke-BatchCallback'; Callback = $onBatch }
}
$results = [Collections.Generic.List[object]]::new()
# The parser alone, called directly: what any dispatch adds is measured against it.
$best = [double]::MaxValue
for ($r = 0; $r -lt $Repeat; $r++) {
    $state = New-BenchState; $watch = [Diagnostics.Stopwatch]::StartNew()
    foreach ($record in $all) { Read-GitStatusBatch @($record) $state }
    $best = [Math]::Min($best, $watch.Elapsed.TotalMilliseconds)
}
$results.Add([ordered]@{ Variant = 'ParserOnly'; BatchSize = $null; MsPer1k = [Math]::Round($best / $Records * 1000, 2) })
foreach ($size in $BatchSize) {
    $batches = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Records; $i += $size) { $batches.Add([object[]]$all[$i..([Math]::Min($i + $size, $Records) - 1)]) }
    foreach ($name in $variants.Keys) {
        $variant = $variants[$name]; $best = [double]::MaxValue
        for ($r = 0; $r -lt $Repeat; $r++) {
            $state = New-BenchState; $watch = [Diagnostics.Stopwatch]::StartNew()
            foreach ($batch in $batches) { & $variant.Dispatch $batch $variant.Callback $state }
            $elapsed = $watch.Elapsed.TotalMilliseconds
            if ($state.Counts.TotalChangedPaths -ne $Records) { throw "$name counted $($state.Counts.TotalChangedPaths) paths." }
            $best = [Math]::Min($best, $elapsed)
        }
        $results.Add([ordered]@{ Variant = $name; BatchSize = $size; MsPer1k = [Math]::Round($best / $Records * 1000, 2) })
    }
}
[ordered]@{ Records = $Records; Repeat = $Repeat; Runtime = $PSVersionTable.PSVersion.ToString(); Results = $results.ToArray() } | ConvertTo-Json -Depth 4 -Compress
