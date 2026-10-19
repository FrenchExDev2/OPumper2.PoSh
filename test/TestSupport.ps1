$script:OP2TestRoot = Split-Path $PSScriptRoot
$script:OP2TestExecutable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
Get-Module 'FrenchExDev.OPumper2*.PoSh' -All | Remove-Module -Force
Import-Module (Join-Path $script:OP2TestRoot 'FrenchExDev.OPumper2.PoSh.psd1') -Global -Force -DisableNameChecking
# A short engine timeout makes a stalled execution fail an assertion quickly instead of waiting for the
# mutation deadline; deliberate waits in tests stay far below it.
$script:OP2TestConfiguration = Join-Path $TestDrive 'test-configuration.yaml'
[IO.File]::WriteAllText($script:OP2TestConfiguration, "general:`n  timeoutSeconds: 20")
# Parallel mutation workers are runspaces of one process: tests never write process environment
# variables. The module reads this runspace-local substitute instead.
InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Database = (Join-Path $TestDrive 'measurements.sqlite'); Config = $script:OP2TestConfiguration } {
    $script:OP2Environment = @{ OPUMPER2_DB_PATH = $Database; OPUMPER2_CONFIG_PATH = $Config }
}

function Set-TestEnvironment {
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][string]$Value)
    InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Name = $Name; Value = $Value } {
        $previous = $script:OP2Environment[$Name]
        $script:OP2Environment[$Name] = $Value
        $previous
    }
}

function Get-TestEnvironment {
    InModuleScope FrenchExDev.OPumper2.PoSh { $script:OP2Environment.Clone() }
}

function New-TestFilter {
    # A validated filter definition from an inline catalogue entry.
    param([hashtable]$Entry)
    InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Entry = $Entry } { ConvertTo-OP2FilterDefinition $Entry 'test' }
}

function Invoke-TestFilter {
    # The report and the projection of recorded lines read through a filter.
    param([object]$Definition, [string[]]$Lines, [int]$ExitCode = 0, [hashtable]$Settings = @{ MaxItems = 20 }, [string]$Stream = 'stdout')
    $contract = New-OPumper2FilterContract -Definition $Definition
    foreach ($line in $Lines) { & $contract.OnRecord ([pscustomobject]@{ Stream = $Stream; Text = $line }) $contract.State }
    $report = & $contract.Complete $contract.State @{ ExitCode = $ExitCode }
    [pscustomobject]@{ Report = $report; Summary = (& $contract.Projection $report $Settings) }
}

function Invoke-TestChild {
    param([string]$Code, [hashtable]$Options = @{})
    if (!$Options.ContainsKey('OnRecord') -and !$Options.ContainsKey('OnBatch') -and !$Options.ContainsKey('OnStdOut') -and !$Options.ContainsKey('OnStdErr')) { $Options.OnRecord = {param($record,$state)} }
    $utf8Code = '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);' + $Code
    FrenchExDev.OPumper2.PoSh\Pump-Me $script:OP2TestExecutable -ArgumentList @('-NoProfile','-NonInteractive','-Command',$utf8Code) -AsObject @Options
}
