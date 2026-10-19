#requires -Version 7.6
[CmdletBinding()]
param()
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'FrenchExDev.OPumper2.PoSh.psd1') -DisableNameChecking
$executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
# A test-like child: one line per test, then a nonzero exit code when one failed.
$tests = '"pass parser", "fail encoder: expected 3, got 4", "pass framer" | ForEach-Object { [Console]::Out.WriteLine($_) }; exit 1'

# The local object stays in a variable, within this one script: the next step depends on its outcome. It holds the
# complete capture, the domain Data and methods, so it is never written to the output, not even to look at it.
$result = pump -AsObject -State ([Collections.Generic.List[string]]::new()) `
    -OnRecord { param($record, $state) if ($record.Text -match '^fail (.+)$') { $state.Add($Matches[1]) } } `
    -Complete { param($state, $execution) [pscustomobject]@{ Failed = $state.ToArray() } } `
    $executable -NoProfile -NonInteractive -Command $tests
if ($result.Outcome -eq 'Success') {
    # Only a field chosen for the question leaves the script.
    "All tests passed in $([int]$result.Execution.ElapsedMs) ms."
    return
}
# The capture answers a question the contract did not foresee, locally: here, the line count of stdout.
$lines = ($result.Capture.Stdout -split "`r?`n" | Where-Object { $_ }).Count
# Out-OPumper2 delivers the result as pump would have: bounded, masked, measured, with its Recall id and excerpt.
New-OPumper2Result -Completion $result -Data ([pscustomobject]@{ Failed = $result.Data.Failed; Lines = $lines }) | Out-OPumper2
