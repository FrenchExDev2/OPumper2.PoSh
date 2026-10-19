function Pump-Me {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs','',Justification='The required public entry point is Pump-Me.')]
    [CmdletBinding(DefaultParameterSetName='Routed')]
    param([Parameter(Mandatory,Position=0)][string]$Command,
        [Parameter(Position=1,ValueFromRemainingArguments)][Alias('NativeArguments')][string[]]$ArgumentList = @(),
        [Parameter(Mandatory,ParameterSetName='Record')][scriptblock]$OnRecord,
        [Parameter(Mandatory,ParameterSetName='Batch')][scriptblock]$OnBatch,
        [Parameter(ParameterSetName='Streams')][scriptblock]$OnStdOut,
        [Parameter(ParameterSetName='Streams')][scriptblock]$OnStdErr,
        [object]$State, [scriptblock]$Complete, [string]$WorkingDirectory = (Get-Location).Path,
        [Collections.IDictionary]$Environment = @{}, [AllowNull()][string]$InputText = $null,
        [char]$StdOutDelimiter = "`n", [char]$StdErrDelimiter = "`n", [string]$Encoding = 'utf-8',
        [int[]]$SuccessExitCodes = @(0), [int]$TimeoutSeconds,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [ValidateRange(1,[int]::MaxValue)][int]$MaxRecordCharacters = 65536,
        [switch]$AsObject, [switch]$AsJson, [switch]$AsYaml, [int]$MaxItems, [int]$MaxOutputBytes, [int]$ExcerptLines)
    # The call's durations count from here: setup up to the child, total up to the stored delivery.
    $entered = Get-OP2Timestamp
    $scope = Enter-OP2Call $entered
    try {
        $options = Resolve-OP2CallOption $PSBoundParameters
        $configuration = $options.Configuration
        $format = $options.Format
        # Plain assignments: Set-Variable honors an inherited -WhatIf and would silently keep the zero defaults.
        $MaxItems = $options.MaxItems; $MaxOutputBytes = $options.MaxOutputBytes
        $TimeoutSeconds = $options.TimeoutSeconds; $ExcerptLines = $options.ExcerptLines
        # A relative directory follows the PowerShell location, which the process current directory does not track.
        $WorkingDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkingDirectory)
        $call = @{ Command = $Command; ArgumentList = $ArgumentList; OnRecord = $OnRecord; OnBatch = $OnBatch; OnStdOut = $OnStdOut; OnStdErr = $OnStdErr
            State = $State; Complete = $Complete; WorkingDirectory = $WorkingDirectory; Environment = $Environment
            InputText = $(if ($PSBoundParameters.ContainsKey('InputText')) { $InputText } else { $null }); StdOutDelimiter = $StdOutDelimiter; StdErrDelimiter = $StdErrDelimiter
            Encoding = $Encoding; SuccessExitCodes = $SuccessExitCodes; TimeoutSeconds = $TimeoutSeconds
            CancellationToken = $CancellationToken; MaxRecordCharacters = $MaxRecordCharacters; Entered = $entered; Context = $scope }
        # The origin identifies the delivery in the measurement history; the command line is kept only as a fingerprint.
        $origin = @{ Command = (@($Command) + $ArgumentList + @($WorkingDirectory)) -join "`0"; Label = [IO.Path]::GetFileName($Command); WorkingDirectory = $WorkingDirectory
            Entered = $entered }
        $route = $null
        if ($PSCmdlet.ParameterSetName -eq 'Routed') { $route = Find-OP2Route $Command $ArgumentList }
        if ($route) { $origin.Route = $route.Id; $origin.Provider = $route.ProviderId }
        $execute = {
            if ($PSCmdlet.ParameterSetName -eq 'Routed') {
                if (!$route) { $missing = New-OP2Completion -Outcome Unsupported -ErrorInfo (New-OP2Error 'RouteNotFound' 'Routing'); Add-OP2Completion $missing; return $missing }
                try { Invoke-OP2DomainCallback $route.Handler @($call) }
                catch { $failed = New-OP2Completion -Outcome Failed -ErrorInfo (New-OP2Error 'HandlerFailed' 'Routing' $_.Exception); Add-OP2Completion $failed; return $failed }
            } else { Invoke-OP2Native -Call $call -Configuration $configuration }
        }
        if ($format -eq 'object') { & $execute; return }
        $values = @(& $execute)
        ConvertTo-OPumper2Output -InputObject $values -Format $format -MaxItems $MaxItems -MaxOutputBytes $MaxOutputBytes -ExcerptLines $ExcerptLines -Configuration $configuration -Origin $origin
    } finally { Exit-OP2Call $scope }
}
