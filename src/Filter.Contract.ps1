# Colors and cursor controls never reach a delivery, whatever a tool's NO_COLOR support.
$script:OP2FilterAnsi = [regex]::new('\x1b\[[0-9;?]*[ -/]*[@-~]')

function New-OP2FilterState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs in-memory parser state without external side effects.')]
    [CmdletBinding()]
    param([object]$Definition, [string]$WorkingDirectory)
    $counters = [ordered]@{}
    foreach ($name in $Definition.Counters.Keys) { $counters[$name] = $(if ($Definition.Counters[$name].Mode -eq 'Last') { $null } else { 0L }) }
    $groups = [ordered]@{}
    foreach ($name in $Definition.Groups.Keys) { $groups[$name] = [ordered]@{} }
    $captures = [ordered]@{}
    foreach ($name in $Definition.Captures.Keys) { $captures[$name] = $null }
    @{ Definition = $Definition; WorkingDirectory = $WorkingDirectory; Lines = 0L; Dropped = 0L
        Kept = [Collections.Generic.List[object]]::new(); KeptIndex = [Collections.Generic.Dictionary[string,object]]::new()
        Counters = $counters; Groups = $groups; Captures = $captures }
}

function Add-OP2FilterKept {
    param([hashtable]$State, [string]$Text, [string]$Stream)
    if ($State.Definition.Dedupe -and $State.KeptIndex.ContainsKey($Text)) { $State.KeptIndex[$Text].Occurrences++; return }
    $entry = [pscustomobject]@{ Text = $Text; Stream = $Stream; Occurrences = 1 }
    $State.Kept.Add($entry)
    if ($State.Definition.Dedupe) { $State.KeptIndex[$Text] = $entry }
}

function Read-OP2FilterBatch {
    # Reads a batch of lines in one call. A dropped line is only counted; any other line feeds counters, groups and
    # captures, and is kept when a Keep expression matches it.
    param([object[]]$Records, [hashtable]$State)
    $definition = $State.Definition
    :record foreach ($record in $Records) {
        $text = $script:OP2FilterAnsi.Replace($record.Text, '')
        $State.Lines++
        foreach ($regex in $definition.Drop) { if ($regex.IsMatch($text)) { $State.Dropped++; continue record } }
        foreach ($name in $definition.Counters.Keys) {
            $counter = $definition.Counters[$name]
            $match = $counter.Regex.Match($text)
            if (!$match.Success) { continue }
            switch ($counter.Mode) {
                'Last' { $State.Counters[$name] = [long]$match.Groups['value'].Value }
                'Sum' { $State.Counters[$name] += [long]$match.Groups['sum'].Value }
                default { $State.Counters[$name]++ }
            }
        }
        foreach ($name in $definition.Groups.Keys) {
            $match = $definition.Groups[$name].Match($text)
            if ($match.Success) { $key = $match.Groups['key'].Value; $State.Groups[$name][$key] = 1 + [long]$State.Groups[$name][$key] }
        }
        foreach ($name in $definition.Captures.Keys) {
            $match = $definition.Captures[$name].Match($text)
            if ($match.Success) { $State.Captures[$name] = $(if ($match.Groups['text'].Success) { $match.Groups['text'].Value } else { $text.Trim() }) }
        }
        foreach ($regex in $definition.Keep) {
            if ($regex.IsMatch($text)) { Add-OP2FilterKept $State $text $record.Stream; continue record }
        }
    }
}

function Complete-OP2FilterOutput {
    param([hashtable]$State, [object]$Execution)
    [pscustomobject]@{
        PSTypeName = 'OPumper2.FilterReport'
        Filter = $State.Definition.Id; WorkingDirectory = $State.WorkingDirectory; ExitCode = $Execution.ExitCode
        Succeeded = ($Execution.ExitCode -in $State.Definition.SuccessExitCodes); Lines = $State.Lines; Dropped = $State.Dropped
        Kept = $State.Kept.ToArray(); Counters = $State.Counters; Groups = $State.Groups; Captures = $State.Captures
    }
}

function New-OPumper2FilterContract {
    # A contract for one catalogue filter: ArgumentList are the native arguments after the command; the filter's own
    # arguments come right after its route tokens, so a later "--" or path keeps its meaning.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs in-memory state and callbacks without executing a command or changing external state.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Definition, [string[]]$ArgumentList = @(), [int]$RouteLength = 1, [string]$WorkingDirectory = (Get-Location).Path)
    $read = Get-Command Read-OP2FilterBatch -CommandType Function
    $finish = Get-Command Complete-OP2FilterOutput -CommandType Function
    $project = Get-Command ConvertTo-OPumper2FilterSummary -CommandType Function
    $head = @($ArgumentList | Select-Object -First ($RouteLength - 1))
    $tail = @($ArgumentList | Select-Object -Skip ($RouteLength - 1))
    $environment = @{ NO_COLOR = '1' }
    foreach ($key in $Definition.Environment.Keys) { $environment[$key] = $Definition.Environment[$key] }
    [pscustomobject]@{
        PSTypeName = 'OPumper2.FilterContract'
        ArgumentList = [string[]](@($head) + @($Definition.Arguments) + @($tail))
        Environment = $environment; SuccessExitCodes = $Definition.SuccessExitCodes
        State = New-OP2FilterState $Definition $WorkingDirectory
        # One reader for both interfaces: a record is a batch of one; routes prefer the batch, read in one call.
        OnRecord = { param($record, $localState) & $read @($record) $localState }.GetNewClosure()
        OnBatch = { param($records, $localState) & $read $records $localState }.GetNewClosure()
        Complete = { param($localState, $execution) & $finish $localState $execution }.GetNewClosure()
        Projection = { param($report, $settings) if ($null -ne $report) { & $project $report $settings } }.GetNewClosure()
    }
}
