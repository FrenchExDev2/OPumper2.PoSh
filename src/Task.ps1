function Invoke-OPumper2Task {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(),
        [switch]$AsObject, [switch]$AsJson, [switch]$AsYaml,
        [int]$MaxItems, [int]$MaxOutputBytes, [int]$ExcerptLines)
    $entered = Get-OP2Timestamp
    $scope = Enter-OP2Call $entered
    try {
        $options = Resolve-OP2CallOption $PSBoundParameters
        $configuration = $options.Configuration
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $format = $options.Format
        $MaxItems = $options.MaxItems; $MaxOutputBytes = $options.MaxOutputBytes; $ExcerptLines = $options.ExcerptLines
        $task = [pscustomobject]@{ InvocationIds = [Collections.Generic.HashSet[string]]::new(); Results = [Collections.Generic.List[object]]::new() }
        $scope.Task = $task
        $errorInfo = $null; $values = @()
        try {
            $values = @(Invoke-OP2DomainCallback $ScriptBlock $ArgumentList | ForEach-Object {
                if (!($_.PSObject.Properties['Kind'] -and $_.Kind -eq 'Completion')) { $_ }
            })
        } catch { $errorInfo = New-OP2Error 'TaskFailed' 'Task' $_.Exception }
        finally { $scope.Task = $null }
        # Results are chronological; the first unsuccessful step explains the task. A body failure always comes last.
        $failures = @($task.Results | Where-Object Outcome -ne 'Success')
        $outcome = $(if ($failures.Count) { $failures[0].Outcome } elseif ($errorInfo) { 'Failed' } else { 'Success' })
        $data = $(if ($values.Count -eq 1) { $values[0] } elseif ($values.Count) { $values } else { $null })
        $execution = New-OP2Execution @{ InvocationIds = @($task.InvocationIds); ElapsedMs = $watch.Elapsed.TotalMilliseconds; Steps = $task.Results.Count }
        $completion = New-OP2Completion -Outcome $outcome -Data $data -Execution $execution -ErrorInfo $errorInfo
        $completion.Completeness.Source = (@($task.Results | Where-Object { !$_.Source }).Count -eq 0)
        $completion.Completeness.Analysis = (!$errorInfo -and @($task.Results | Where-Object { !$_.Analysis }).Count -eq 0)
        $completion.Truncation.Applied = (@($task.Results | Where-Object Truncated).Count -gt 0)
        $completion.Execution.Issues = @($failures | Select-Object -First 20)
        Add-OP2Completion $completion
        ConvertTo-OPumper2Output -InputObject @($completion) -Format $format -MaxItems $MaxItems -MaxOutputBytes $MaxOutputBytes -ExcerptLines $ExcerptLines -Configuration $configuration -Origin @{ Entered = $entered }
    } finally { Exit-OP2Call $scope }
}
