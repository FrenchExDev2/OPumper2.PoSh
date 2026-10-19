#requires -Version 7.6
[CmdletBinding()]
param([switch]$AsObject)
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'FrenchExDev.OPumper2.PoSh.psd1') -DisableNameChecking
$executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$state = @{ Lines = 0; Diagnostics = 0 }
$output = $(if ($AsObject) { @{ AsObject = $true } } else { @{ AsYaml = $true } })
Pump-Me $executable -ArgumentList @('-NoProfile','-NonInteractive','-Command','[Console]::Out.WriteLine("ready"); [Console]::Error.WriteLine("notice")') `
    -State $state -OnStdOut { param($line,$s) $s.Lines++ } -OnStdErr { param($line,$s) $s.Diagnostics++ } `
    -Complete { param($s,$execution) [pscustomobject]@{ Lines = $s.Lines; Diagnostics = $s.Diagnostics; ExitCode = $execution.ExitCode } } @output
