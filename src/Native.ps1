function Invoke-OP2Native {
    # The engine assembly reads, decodes, captures and frames both streams on a background task; this thread keeps the
    # deadline, the termination policy and the callbacks, which receive the framed records batch by batch.
    [CmdletBinding()]
    param([hashtable]$Call, [hashtable]$Configuration)
    $ErrorActionPreference = 'Stop'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $paths = [Collections.Generic.List[string]]::new()
    $context = New-OP2CallbackContext $Call
    $outcome = 'Success'; $errorInfo = $null; $exitCode = $null; $run = $null; $started = $false
    $sourceComplete = $false
    # The phases of the call, in milliseconds (Execution.Timing); Save-OP2Invocation stores them.
    $timing = [ordered]@{ SetupMs = $null; ProcessMs = $null; BackpressureMs = $null; CallbackMs = $null; CompleteMs = $null; CaptureMs = $null }
    # The callbacks alone, in clock ticks: the waits for records stay outside it.
    $callbackTicks = 0L
    # A wait returns as soon as records arrive or the child exits: the interval only bounds deadline checks.
    $interval = 50
    try {
        $Call.CancellationToken.ThrowIfCancellationRequested()
        $encoding = [Text.Encoding]::GetEncoding($Call.Encoding,[Text.EncoderExceptionFallback]::new(),[Text.DecoderExceptionFallback]::new())
        $run = [FrenchExDev.OPumper2.Engine.NativeRun]::new((New-OP2StartInfo $Call), $encoding, $Call.StdOutDelimiter, $Call.StdErrDelimiter,
            $Call.MaxRecordCharacters, $Call.InputText, $context.Counter)
        # Setup: from the entry into pump (configuration, route, contract) to the start of the child. A routed call
        # starts its child through a pump call of its handler: its setup counts from the outer entry, which the first
        # native call takes.
        $entered = $Call['Entered']
        $scope = $Call['Context']
        if ($scope -and $null -ne $scope.Account.PendingEntered) { $entered = $scope.Account.PendingEntered; $scope.Account.PendingEntered = $null }
        if ($null -ne $entered) { $timing.SetupMs = Get-OP2Duration $entered (Get-OP2Timestamp) }
        $started = $run.Start()
        Start-OP2TokenizerWarmup $Configuration
        $stdout = New-OP2Spool $paths
        $stderr = New-OP2Spool $paths
        $run.Read($stdout.Spool, $stdout.Path, $stderr.Spool, $stderr.Path)
        # Once the termination grace period has abandoned the streams, those still held open (for example by an
        # orphaned grandchild outside the killed tree) are left behind: a timeout always returns.
        while (!$run.IsComplete) {
            if ($Call.CancellationToken.IsCancellationRequested -or $watch.Elapsed.TotalSeconds -ge $Call.TimeoutSeconds) {
                $outcome = $(if ($Call.CancellationToken.IsCancellationRequested) { 'Cancelled' } else { 'Timeout' })
                $errorInfo = New-OP2Error $outcome 'Execution'
                Invoke-OP2Termination $run $watch.Elapsed.TotalSeconds $Call.TimeoutSeconds
            }
            $batch = $run.Next($interval)
            $dispatching = Get-OP2Timestamp
            Invoke-OP2Dispatch $batch $context
            $callbackTicks += (Get-OP2Timestamp) - $dispatching
        }
        # The engine's wait also times the exit, should its Exited event still be running.
        $run.WaitForExit(); $exitCode = $run.Process.ExitCode
        $sourceComplete = ($outcome -eq 'Success')
        $framing = Get-OP2FramingError $context
        if ($outcome -eq 'Success' -and $framing) { $outcome = 'Failed'; $errorInfo = $framing }
        if ($outcome -eq 'Success' -and $exitCode -notin $Call.SuccessExitCodes) { $outcome = 'Failed'; $errorInfo = New-OP2Error 'NativeFailed' 'Execution' }
    } catch {
        if ($outcome -eq 'Success') {
            if ($Call.CancellationToken.IsCancellationRequested) { $outcome='Cancelled'; $errorInfo=New-OP2Error 'Cancelled' 'Execution' }
            else {
                # An engine failure arrives wrapped by the method call: the delivery names its cause.
                $failure = $_.Exception
                if ($failure -is [Management.Automation.MethodInvocationException]) { $failure = $failure.InnerException }
                $outcome = 'Failed'; $errorInfo = New-OP2Error 'ExecutionFailed' 'Execution' $failure
            }
        }
    } finally {
        if ($started) {
            if (!$run.Process.HasExited) { $run.Process.Kill($true) }
            $run.WaitForExit(); $exitCode = $run.Process.ExitCode
        }
        if ($run) { $run.Dispose() }
    }
    # Captures exist once the streams were read; their spools are closed.
    $captures = @($(if ($run -and $run.Stdout) { $run.Stdout; $run.Stderr }))
    $stdoutBytes = 0L; $stderrBytes = 0L
    foreach ($capture in $captures) {
        if ($capture.Name -eq 'stdout') { $stdoutBytes += $capture.Bytes } else { $stderrBytes += $capture.Bytes }
    }
    # The engine timed the child and the waits of its readers on the full queue: the time the callbacks held it back.
    if ($run -and $null -ne $run.ProcessElapsed) { $timing.ProcessMs = $run.ProcessElapsed.TotalMilliseconds }
    if ($run) { $timing.BackpressureMs = $run.Backpressure.TotalMilliseconds }
    $timing.CallbackMs = Get-OP2Duration 0 $callbackTicks
    # Timing stays on the local object: delivering it would cost every call tokens.
    $execution = New-OP2Execution @{ ExitCode = $exitCode; InvocationIds = @([guid]::NewGuid().ToString('N')); ElapsedMs = $watch.Elapsed.TotalMilliseconds; FinalizerError = $null
        StdoutBytes = $stdoutBytes; StderrBytes = $stderrBytes; Records = $context.Counter.Sequence; Timing = $timing }
    $completing = Get-OP2Timestamp
    $completion = Complete-OP2Call $Call $context $execution $outcome $errorInfo $sourceComplete
    $timing.CompleteMs = Get-OP2Duration $completing (Get-OP2Timestamp)
    $completion.Measurement.SourceBytes = Get-OP2SourceByteCount $execution
    try {
        # Every local completion keeps the complete decoded streams, successful or not. Read them before the
        # temporary captures are deleted.
        $capturing = Get-OP2Timestamp
        $completion.Capture = Read-OP2Capture $captures $Call.Encoding $sourceComplete
        $timing.CaptureMs = Get-OP2Duration $capturing (Get-OP2Timestamp)
        if (@($captures | Where-Object { !$_.CaptureComplete }).Count) { $completion.Measurement.Status = 'CaptureUnavailable' }
        else { Save-OP2Invocation $completion $Call.WorkingDirectory ([IO.Path]::GetFileName($Call.Command)) $Configuration}
    } finally { foreach ($path in $paths) { [IO.File]::Delete($path) } }
    Add-OP2Completion $completion
    $completion
}
