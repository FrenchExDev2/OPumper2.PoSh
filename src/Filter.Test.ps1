function Get-OP2SummaryValue {
    # A section of a delivered summary, or one entry of it (Section.Entry); nothing when absent.
    param([Collections.IDictionary]$Summary, [string]$Key)
    $parts = $Key -split '\.', 2
    if ($parts.Count -eq 1) { return $Summary[$Key] }
    $section = $Summary[$parts[0]]
    if ($null -eq $section) { return $null }
    return $section[$parts[1]]
}

function Get-OP2FilterTestWarning {
    # What the tests of a filter that keeps lines leave unproven: a successful run (NoSuccessCase) or a failed one
    # (NoFailureCase), judged by the filter's own success exit codes. A filter without Keep has nothing to show.
    param([object]$Definition)
    if (!@($Definition.Keep).Count) { return @() }
    $codes = @($Definition.Tests | ForEach-Object ExitCode)
    @($(if (!@($codes | Where-Object { $_ -in $Definition.SuccessExitCodes }).Count) { 'NoSuccessCase' }
        if (!@($codes | Where-Object { $_ -notin $Definition.SuccessExitCodes }).Count) { 'NoFailureCase' }))
}

function Invoke-OP2FilterTest {
    # One built-in test read through its filter as a routed call reads it, without a process or a measurement: the
    # differences between the delivered summary and what the test expects. Values compare as text, arrays joined with
    # '|', as the delivery normalizes them (ConvertTo-OPumper2Line).
    param([object]$Definition, [object]$Test, [string[]]$Warning = @())
    $contract = New-OPumper2FilterContract -Definition $Definition
    # A routed call hands the records over a batch at a time; the test's lines are one batch.
    $records = [object[]]@(foreach ($line in $Test.Lines) { [pscustomobject]@{ Stream = $Test.Stream; Text = $line } })
    & $contract.OnBatch $records $contract.State
    $report = & $contract.Complete $contract.State @{ ExitCode = $Test.ExitCode }
    $summary = & $contract.Projection $report @{ MaxItems = 20 }
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($key in @(@($Test.Expect.get_Keys()) | Sort-Object)) {
        $expected = @($Test.Expect[$key]) -join '|'
        $actual = @(Get-OP2SummaryValue $summary $key) -join '|'
        if ($actual -cne $expected) { $failures.Add("$key`: expected '$expected', got '$actual'") }
    }
    foreach ($key in $Test.Absent) {
        # A missing section reads as one $null: absent means no value at all.
        $actual = @(Get-OP2SummaryValue $summary $key | Where-Object { $null -ne $_ })
        if ($actual.Count) { $failures.Add("$key`: expected absent, got '$($actual -join '|')'") }
    }
    [pscustomobject]@{ PSTypeName = 'OPumper2.FilterTest'; Filter = $Definition.Id; Test = $Test.Name; Untested = $false; Passed = !$failures.Count; Failures = $failures.ToArray()
        Warnings = $Warning }
}

function Test-OPumper2Filter {
    # Runs the tests built into a catalogue's filters: one result per test, and one per filter without any. RequireAll
    # fails those untested filters. Warnings name what a filter's tests leave unproven (NoSuccessCase, NoFailureCase)
    # without failing them. Nothing runs natively and nothing is measured or stored.
    [CmdletBinding()]
    [OutputType('OPumper2.FilterTest')]
    param([Parameter(Mandatory)][string]$Path, [string[]]$Id, [switch]$RequireAll)
    foreach ($definition in @(Get-OPumper2Filter -Path $Path -Id $Id)) {
        $warning = Get-OP2FilterTestWarning $definition
        if (!$definition.Tests.Count) {
            [pscustomobject]@{ PSTypeName = 'OPumper2.FilterTest'; Filter = $definition.Id; Test = $null; Untested = $true; Passed = !$RequireAll
                Failures = @($(if ($RequireAll) { 'The filter has no test.' })); Warnings = $warning }
            continue
        }
        foreach ($test in $definition.Tests) { Invoke-OP2FilterTest $definition $test $warning }
    }
}
