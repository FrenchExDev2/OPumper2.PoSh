function Invoke-OP2DomainCallback {
    # Called once per record: a simple function and an anonymous process block cost a fraction of an advanced function
    # piped into ForEach-Object, and still stream each value, unenumerated, before a later failure.
    param([scriptblock]$Callback, [object[]]$Arguments)
    & $Callback @Arguments *>&1 | & {
        process {
            if ($_ -is [Management.Automation.ErrorRecord] -or $_ -is [Management.Automation.InformationalRecord] -or $_ -is [Management.Automation.InformationRecord]) {
                throw 'Callbacks must emit domain values, not diagnostic streams.'
            }
            ,$_
        }
    }
}

function New-OP2CallbackContext {
    # The dispatch state of one call, live or replayed: its callbacks, its state, its first callback failure, and the
    # record accounting the engine assembly keeps while it frames.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs an in-memory value without external side effects.')]
    [CmdletBinding()]
    param([hashtable]$Call)
    [pscustomobject]@{ OnRecord = $Call.OnRecord; OnBatch = $Call['OnBatch']; OnStdOut = $Call.OnStdOut; OnStdErr = $Call.OnStdErr
        State = $Call.State; Failure = $null; Counter = [FrenchExDev.OPumper2.Engine.RecordCounter]::new(); MaxRecordCharacters = $Call.MaxRecordCharacters }
}

function Get-OP2FramingError {
    # A failed record callback explains a call first, then records lost to the record size limit.
    param([object]$Context)
    if ($Context.Failure) { return $Context.Failure }
    if ($Context.Counter.Lost) { return New-OP2Error 'RecordLimit' 'Framing' }
    return $null
}

function Complete-OP2Call {
    # Runs the finalizer, then builds the completion of a framed call, live or replayed.
    param([hashtable]$Call, [object]$Context, [hashtable]$Execution, [string]$Outcome, [object]$ErrorInfo, [bool]$SourceComplete)
    $data = $null
    try {
        if ($Call.Complete) {
            $values = @(Invoke-OP2DomainCallback $Call.Complete @($Call.State,$Execution))
            $data = $(if ($values.Count -eq 1) { $values[0] } elseif ($values.Count) { $values } else { $null })
        }
    } catch {
        $Execution.FinalizerError = New-OP2Error 'FinalizerFailed' 'Complete' $_.Exception
        if ($Outcome -eq 'Success') { $Outcome = 'Failed'; $ErrorInfo = $Execution.FinalizerError }
    }
    $completion = New-OP2Completion -Outcome $Outcome -Data $data -Execution $Execution -ErrorInfo $ErrorInfo
    $completion.Completeness.Source = $SourceComplete
    $completion.Completeness.Analysis = ($SourceComplete -and !$Context.Failure -and !$Context.Counter.Lost -and !$Execution.FinalizerError)
    if ($Context.Counter.Lost) { $completion.Truncation = @{ Applied = $true; Reasons = @('RecordLimit'); OmittedRecords = $Context.Counter.Lost } }
    return $completion
}
