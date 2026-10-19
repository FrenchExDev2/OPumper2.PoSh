#requires -Version 7.6
[CmdletBinding()]
param()
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'FrenchExDev.OPumper2.PoSh.psd1') -DisableNameChecking
$executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
# A build-like child: progress on stdout, then an error on stderr and a nonzero exit code.
$build = '1..50 | ForEach-Object { [Console]::Out.WriteLine("compiled unit $_") }; [Console]::Error.WriteLine("error E42: missing symbol; token=abc"); exit 2'

# Options come first; -NoProfile, -NonInteractive and -Command reach the child unchanged.
# The contract keeps warnings only, so the failure is explained by the delivered excerpt.
pump -ExcerptLines 3 -State @{ Warnings = 0 } -OnRecord { param($record,$state) if ($record.Text -match 'warning') { $state.Warnings++ } } `
    -Complete { param($state,$execution) [pscustomobject]@{ Warnings = $state.Warnings } } `
    $executable -NoProfile -NonInteractive -Command $build
