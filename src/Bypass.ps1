# Where a bypassed command's streams go: the console, unless this runspace substitutes writers (stdout, stderr).
# The console is shared by every runspace of the process; a substitute keeps concurrent hosts apart.
$script:OP2BypassWriter = $null

function Get-OP2BypassWriter {
    param([string]$Stream)
    if ($null -ne $script:OP2BypassWriter) { return $script:OP2BypassWriter[$Stream] }
    if ($Stream -eq 'stderr') { return [Console]::Error }
    return [Console]::Out
}

function Invoke-OPumper2Bypass {
    # For people, never for agents: runs a command and writes its output as is, measured as a delivery of everything
    # it printed under the 'bypass' route, so the history shows what pump would have saved. Sets $LASTEXITCODE.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars','',Justification='A bypassed native command reports its exit code like any native command.')]
    [CmdletBinding()]
    param([Parameter(Mandatory, Position=0)][string]$Command, [Parameter(Position=1, ValueFromRemainingArguments)][string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location).Path)
    $configuration = Get-OP2Configuration
    $write = { param($record) (Get-OP2BypassWriter $record.Stream).WriteLine($record.Text) }
    $native = Pump-Me $Command -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -OnRecord $write -AsObject
    $directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkingDirectory)
    $origin = @{ Route = 'bypass'; Label = [IO.Path]::GetFileName($Command); WorkingDirectory = $directory
        Command = (@($Command) + $ArgumentList + @($directory)) -join "`0" }
    Save-OP2Delivery -Completion $native -Text "$($native.Capture.Stdout)$($native.Capture.Stderr)" -Configuration $configuration -Origin $origin -Format 'raw'
    $global:LASTEXITCODE = $native.Execution.ExitCode
}
