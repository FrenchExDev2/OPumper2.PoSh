BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Built-in filter tests' {
    It 'refuses a malformed test with its filter and its name' {
        $base = @{ Id = 'x'; Routes = @('tool'); Counters = @{ Errors = 'error' }; Groups = @{ Files = '^(?<key>\S+):' }; Captures = @{ Last = '^last' }; Keep = @('^!') }
        foreach ($case in @(
            @('x', '*a test must be a mapping*'), @(@{ Name = 'a'; Expect = @{ Lines = '1' }; Colour = 1 }, "*unknown test key 'Colour'*"),
            @(@{ Expect = @{ Lines = '1' } }, '*a test needs a Name*'), @(@{ Name = 'a'; Lines = @('x', 1); Expect = @{ Lines = '1' } }, "*test 'a': Lines must be strings*"),
            @(@{ Name = 'a'; ExitCode = '1'; Expect = @{ Lines = '1' } }, "*test 'a': ExitCode must be an integer*"),
            @(@{ Name = 'a'; Stream = 'both'; Expect = @{ Lines = '1' } }, "*test 'a': Stream must be stdout or stderr*"),
            @(@{ Name = 'a'; Expect = 'x' }, "*test 'a': Expect must be a mapping*"), @(@{ Name = 'a' }, "*test 'a': a test needs Expect or Absent*"),
            @(@{ Name = 'a'; Expect = @{ 'Counters.Warnings' = '1' } }, "*Expect names 'Counters.Warnings', which the filter does not deliver*"),
            @(@{ Name = 'a'; Expect = @{ 'Captures.First' = 'x' } }, "*Expect names 'Captures.First'*"), @(@{ Name = 'a'; Expect = @{ 'Dirs.src' = '1' } }, "*Expect names 'Dirs.src'*"),
            @(@{ Name = 'a'; Expect = @{ Counters = '1' } }, "*Expect names 'Counters'*"), @(@{ Name = 'a'; Absent = @('Dirs') }, "*Absent names 'Dirs'*"))) {
            $entry = $base.Clone(); $entry.Tests = @($case[0])
            { New-TestFilter $entry } | Should -Throw $case[1]
        }
        $entry = $base.Clone(); $entry.Tests = @(@{ Name = 'a'; Expect = @{ Lines = '0' } }, @{ Name = 'A'; Expect = @{ Lines = '0' } })
        { New-TestFilter $entry } | Should -Throw "*duplicate test 'A'*"
        $entry = $base.Clone(); $entry.Remove('Keep'); $entry.Tests = @(@{ Name = 'a'; Expect = @{ Kept = 'x' } })
        { New-TestFilter $entry } | Should -Throw "*Expect names 'Kept'*"
        # A counter whose name holds a dot is one name: only the first dot ends the section.
        $dotted = $base.Clone(); $dotted.Counters = @{ 'Errors.cs' = 'error' }; $dotted.Tests = @(@{ Name = 'dotted'; Expect = @{ 'Counters.Errors.cs' = '0' } })
        (New-TestFilter $dotted).Tests[0].Expect.Keys | Should -Be 'Counters.Errors.cs'
        $entry = $base.Clone(); $entry.Tests = @(@{ Name = 'every section'; Expect = @{ Filter = 'x'; Succeeded = 'True'; Lines = '0'; Kept = ''; 'Counters.Errors' = ''; 'Captures.Last' = ''; 'Files.a' = '' }; Absent = @('Kept', 'Counters', 'Captures', 'Files', 'Files.a', 'Counters.Errors') })
        $test = (New-TestFilter $entry).Tests[0]
        "$($test.Name)|$($test.ExitCode)|$($test.Stream)|$($test.Lines.Count)|$($test.Absent.Count)" | Should -BeExactly 'every section|0|stdout|0|6'
        (New-TestFilter $base).Tests.Count | Should -Be 0
    }
    It 'warns, without failing, when a filter that keeps lines lacks a successful or a failed case' {
        $catalogue = Join-Path $TestDrive 'warnings'; [void][IO.Directory]::CreateDirectory($catalogue)
        [IO.File]::WriteAllText((Join-Path $catalogue 'w.psd1'), @'
@{ Filters = @(
    @{ Id = 'w.failed'; Routes = @('w failed'); Description = 'd'; Source = 's'; Keep = @('error'); Tests = @(@{ Name = 'fails'; ExitCode = 1; Expect = @{ Lines = '0' } }) }
    @{ Id = 'w.passed'; Routes = @('w passed'); Description = 'd'; Source = 's'; Keep = @('error'); Tests = @(@{ Name = 'passes'; Expect = @{ Lines = '0' } }) }
    @{ Id = 'w.both'; Routes = @('w both'); Description = 'd'; Source = 's'; Keep = @('error'); SuccessExitCodes = @(0, 1); Tests = @(@{ Name = 'no match'; ExitCode = 1; Expect = @{ Lines = '0' } }, @{ Name = 'broken'; ExitCode = 2; Expect = @{ Lines = '0' } }) }
    @{ Id = 'w.none'; Routes = @('w none'); Description = 'd'; Source = 's'; Counters = @{ Rows = '.' }; Tests = @(@{ Name = 'counts'; Expect = @{ Lines = '0' } }) }
    @{ Id = 'w.untested'; Routes = @('w untested'); Description = 'd'; Source = 's'; Keep = @('error') }
) }
'@)
        $results = @(Test-OPumper2Filter -Path $catalogue)
        ($results | ForEach-Object { "$($_.Filter)=$($_.Passed)/$($_.Warnings -join '+')" }) -join ',' | Should -BeExactly 'w.failed=True/NoSuccessCase,w.passed=True/NoFailureCase,w.both=True/,w.both=True/,w.none=True/,w.untested=True/NoSuccessCase+NoFailureCase'
    }
    It 'reads a test with the delivery budget of a call: twenty items' {
        $catalogue = Join-Path $TestDrive 'budget'; [void][IO.Directory]::CreateDirectory($catalogue)
        $kept = (1..20 | ForEach-Object { "'l$_'" }) -join ', '
        [IO.File]::WriteAllText((Join-Path $catalogue 'many.psd1'), "@{ Filters = @(@{ Id = 'tool.many'; Routes = @('tool many'); Description = 'd'; Source = 's'; Keep = @('.'); Tests = @(@{ Name = 'budget'; Lines = @($((1..21 | ForEach-Object { "'l$_'" }) -join ', ')); Expect = @{ Kept = @($kept) } }) }) }")
        $result = @(Test-OPumper2Filter -Path $catalogue)
        "$($result.Count)|$($result[0].Passed)|$($result[0].Failures -join ';')" | Should -BeExactly '1|True|'
    }
    It 'runs each test through its filter as a call would, and reports every difference' {
        $catalogue = Join-Path $TestDrive 'catalogue'; [void][IO.Directory]::CreateDirectory($catalogue)
        $text = @'
@{ Filters = @(
    @{ Id = 'tool.run'; Routes = @('tool run'); Description = 'd'; Source = 's'; Counters = @{ Errors = 'error' }; Groups = @{ Files = '^(?<key>\S+): error' }; Keep = @('error')
       Tests = @(
           @{ Name = 'passes'; ExitCode = 1; Stream = 'stderr'; Lines = @('a.cs: error one', 'a.cs: error two', 'fine'); Expect = @{ Succeeded = 'False'; Lines = '3'; 'Counters.Errors' = '2'; 'Files.a.cs' = '2'; Kept = @('a.cs: error one', 'a.cs: error two') }; Absent = @('Captures') }
           @{ Name = 'differs'; Lines = @('a.cs: error one'); Expect = @{ 'Counters.Errors' = '5'; 'Files.b.cs' = '1' }; Absent = @('Kept', 'Files.a.cs') }
           @{ Name = 'no group'; Lines = @('fine'); Expect = @{ 'Files.a.cs' = '' }; Absent = @('Files') }
       ) }
    @{ Id = 'tool.idle'; Routes = @('tool idle'); Description = 'd'; Source = 's' }
) }
'@
        [IO.File]::WriteAllText((Join-Path $catalogue 'tool.psd1'), $text)
        $results = @(Test-OPumper2Filter -Path $catalogue)
        ($results | ForEach-Object { "$($_.Filter)/$($_.Test)=$($_.Passed)/$($_.Untested)" }) -join ',' | Should -BeExactly 'tool.run/passes=True/False,tool.run/differs=False/False,tool.run/no group=True/False,tool.idle/=True/True'
        $results[0].PSObject.TypeNames[0] | Should -BeExactly 'OPumper2.FilterTest'
        ($results[1].Failures -join ' | ') | Should -BeExactly "Counters.Errors: expected '5', got '1' | Files.b.cs: expected '1', got '' | Kept: expected absent, got 'a.cs: error one' | Files.a.cs: expected absent, got '1'"
        $results[3].Failures.Count | Should -Be 0
        $strict = @(Test-OPumper2Filter -Path $catalogue -Id tool.idle -RequireAll)
        "$($strict.Count)|$($strict[0].Passed)|$($strict[0].Failures)" | Should -BeExactly '1|False|The filter has no test.'
    }
}
