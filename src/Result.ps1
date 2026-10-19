function New-OP2Execution {
    # Common fields are unknown by default. Native, replay and task details are added only when applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs an in-memory value without external side effects.')]
    param([Collections.IDictionary]$Values = @{})
    $execution = @{ ExitCode = $null; InvocationIds = @(); ElapsedMs = $null }
    foreach ($name in $Values.Keys) { $execution[$name] = $Values[$name] }
    return $execution
}

function New-OP2Completion {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs an in-memory value without external side effects.')]
    [CmdletBinding()]
    param([string]$Outcome = 'Success', [object]$Data, [object]$Execution, [object]$ErrorInfo)
    if (!$Execution) { $Execution = New-OP2Execution }
    [pscustomobject]@{
        PSTypeName = 'OPumper2.Completion'
        Kind = 'Completion'; SchemaVersion = 2; Outcome = $Outcome; Data = $Data
        Execution = $Execution; Error = $ErrorInfo
        Completeness = @{ Source = ($Outcome -eq 'Success'); Analysis = ($Outcome -eq 'Success') }
        Truncation = @{ Applied = $false; Reasons = @(); OmittedRecords = 0 }
        Measurement = @{ Status = 'NotDelivered'; SourceBytes = $null; SourceTokens = $null; OutputBytes = $null; OutputTokens = $null }
        Presentation = $null; Capture = $null
    }
}

function New-OPumper2Result {
    # The Result pattern for handlers and local scripts: a completion keeps the complete domain Data on the local
    # object, and its projection replaces Data in JSON and YAML deliveries only.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs an in-memory value without external side effects.')]
    [CmdletBinding(DefaultParameterSetName='New')]
    param([Parameter(Mandatory,ParameterSetName='Completion')][object]$Completion,
        [Parameter(ParameterSetName='New')][ValidateSet('Success','Failed','Timeout','Cancelled','Unsupported')][string]$Outcome = 'Success',
        [Parameter(ParameterSetName='New')][string]$ErrorCode = 'HandlerFailed',
        [Parameter(ParameterSetName='New')]$ErrorMessage,
        [object]$Data, [scriptblock]$Projection, [ValidateRange(0,[int]::MaxValue)][Nullable[int]]$ExcerptLines)
    if ($PSCmdlet.ParameterSetName -eq 'Completion') {
        if (!$Completion.PSObject.Properties['Kind'] -or $Completion.Kind -ne 'Completion') { throw 'A completion object is required.' }
        # A copy: the wrapped completion, already accounted by its task, stays unchanged.
        $result = $Completion.PSObject.Copy()
        if ($PSBoundParameters.ContainsKey('Data')) { $result.Data = $Data }
    } else {
        $errorInfo = $null
        if ($Outcome -ne 'Success') { $errorInfo = New-OP2Error $ErrorCode 'Handler'; $errorInfo.Message = $ErrorMessage }
        $result = New-OP2Completion -Outcome $Outcome -Data $Data -ErrorInfo $errorInfo
        Add-OP2Completion $result
    }
    $result | Add-Member -NotePropertyName Presentation -NotePropertyValue @{ Projection = $Projection; ExcerptLines = $ExcerptLines } -Force
    $result
}

function Add-OP2Completion {
    param([object]$Completion)
    foreach ($task in @(Get-OP2CallTask)) {
        foreach ($id in $Completion.Execution.InvocationIds) { [void]$task.InvocationIds.Add($id) }
        $task.Results.Add([pscustomobject]@{
            Outcome = $Completion.Outcome; ExitCode = $Completion.Execution['ExitCode']; Error = $Completion.Error; FinalizerError = $Completion.Execution['FinalizerError']
            Analysis = $Completion.Completeness.Analysis; Source = $Completion.Completeness.Source
            Truncated = $Completion.Truncation.Applied; Capture = $Completion.Capture
        })
    }
}

function Add-OP2Truncation {
    param([object]$Completion, [string]$Reason, [long]$Omitted = 0)
    # Reasons accumulate: a later limit never hides an earlier omission.
    $Completion.Truncation.Applied = $true
    if ($Reason -notin $Completion.Truncation.Reasons) { $Completion.Truncation.Reasons += $Reason }
    $Completion.Truncation.OmittedRecords += $Omitted
}

function New-OP2Error {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs an in-memory diagnostic without external side effects.')]
    [CmdletBinding()]
    param([string]$Code, [string]$Phase, [object]$Exception)
    @{ Code = $Code; Phase = $Phase; ExceptionType = $(if ($Exception) { $Exception.GetType().FullName } else { $null })
        Message = $(if ($Exception) { $Exception.Message } else { $null }) }
}
