BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Filter interpreter' {
    It 'drops, counts, groups, captures and keeps lines, colors removed' {
        $definition = New-TestFilter @{ Id = 'x'; Routes = @('tool'); Drop = @('^#')
            Counters = @{ Last = 'v=(?<value>\d+)'; Total = 's=(?<sum>\d+)'; Errors = 'error'; Never = 'never'; Unset = 'u=(?<value>\d+)' }
            Groups = @{ Kinds = '^(?<key>error|warning):' }; Captures = @{ Final = 'done (?<text>\w+)'; Whole = 'summary' }
            Keep = @('^error', '^warning') }
        $lines = @("`e[31merror: one`e[0m v=1 s=2", '# comment error', 'warning: two v=5 s=3', 'error: one v=1 s=2', '  summary line  ', 'done ok', 'noise')
        $run = Invoke-TestFilter $definition $lines 3
        $report = $run.Report
        "$($report.Filter)|$($report.ExitCode)|$($report.Succeeded)|$($report.Lines)|$($report.Dropped)" | Should -BeExactly 'x|3|False|7|1'
        (@($report.Counters.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'Errors=2,Last=1,Never=0,Total=7,Unset='
        (@($report.Groups.Kinds.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'error=2,warning=1'
        "$($report.Captures.Final)|$($report.Captures.Whole)" | Should -BeExactly 'ok|summary line'
        (@($report.Kept | ForEach-Object { "$($_.Text)/$($_.Stream)/$($_.Occurrences)" }) -join '|') | Should -BeExactly 'error: one v=1 s=2/stdout/2|warning: two v=5 s=3/stdout/1'
        $ordered = New-TestFilter @{ Id = 'y'; Routes = @('tool'); Keep = @('.'); Dedupe = $false; SuccessExitCodes = @(0,1) }
        $kept = (Invoke-TestFilter $ordered @('a','a','b') 1 -Stream stderr).Report
        (@($kept.Kept | ForEach-Object { "$($_.Text)/$($_.Stream)/$($_.Occurrences)" }) -join '|') | Should -BeExactly 'a/stderr/1|a/stderr/1|b/stderr/1'
        $kept.Succeeded | Should -BeTrue
    }
    It 'places the filter arguments after the route tokens and sets its environment' {
        $definition = New-TestFilter @{ Id = 'z'; Routes = @('tool sub'); Arguments = @('--plain'); Environment = @{ NO_COLOR = '0'; MODE = 'ci' } }
        $contract = New-OPumper2FilterContract -Definition $definition -ArgumentList @('sub','--','path') -RouteLength 2 -WorkingDirectory 'C:\work'
        ($contract.ArgumentList -join ' ') | Should -BeExactly 'sub --plain -- path'
        (@($contract.Environment.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'MODE=ci,NO_COLOR=0'
        $contract.State.WorkingDirectory | Should -BeExactly 'C:\work'
        ($contract.SuccessExitCodes -join ',') | Should -BeExactly '0'
        (New-OPumper2FilterContract -Definition $definition -ArgumentList @('x','y')).ArgumentList -join ' ' | Should -BeExactly '--plain x y'
        (New-OPumper2FilterContract -Definition (New-TestFilter @{ Id = 'w'; Routes = @('t') })).Environment.NO_COLOR | Should -BeExactly '1'
        & $contract.Projection $null @{} | Should -BeNullOrEmpty
    }
}

Describe 'Filter explanation' {
    It 'explains a failure only by its kept lines' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $kept = @([pscustomobject]@{ Text = 'error'; Stream = 'stdout'; Occurrences = 1 })
            (@($null, [pscustomobject]@{ Succeeded = $false; Kept = $kept }, [pscustomobject]@{ Succeeded = $false; Kept = @() },
                [pscustomobject]@{ Succeeded = $true; Kept = $kept }) | ForEach-Object { Test-OP2FilterExplained $_ }) -join ',' | Should -BeExactly 'False,True,False,False'
        }
    }
}

Describe 'Filter projection' {
    It 'delivers counters, captures, groups by frequency and kept lines with repetitions' {
        $definition = New-TestFilter @{ Id = 'x'; Routes = @('tool'); Counters = @{ Seen = '.'; Unset = 'u=(?<value>\d+)' }
            Groups = @{ Kinds = '^(?<key>\w+):'; Empty = '^never (?<key>x)' }; Captures = @{ Final = "^done"; Missing = '^absent' }; Keep = @(':') }
        $summary = (Invoke-TestFilter $definition @('b: 1', 'a: 2', 'b: 1', 'c: 3', "done  `t now")).Summary
        (@($summary.Keys) -join ',') | Should -BeExactly 'Filter,Succeeded,Lines,Counters,Captures,Kinds,Kept'
        (@($summary.Counters.Keys) -join ',') | Should -BeExactly 'Seen'
        $summary.Captures.Final | Should -BeExactly 'done now'
        (@($summary.Kinds.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'b=2,a=1,c=1'
        ($summary.Kept -join '|') | Should -BeExactly 'b: 1 (x2)|a: 2|c: 3'
        $bounded = (Invoke-TestFilter $definition @('b: 1', 'a: 2', 'c: 3') -Settings @{ MaxItems = 1 }).Summary
        (@($bounded.Omitted.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'Kinds=2,Kept=2'
        $long = @('firstlongkeyname: x', 'secondlongkeyname: y', 'thirdlongkeyname: z')
        $budget = (Invoke-TestFilter $definition $long -Settings @{ MaxItems = 20; MaxOutputBytes = 180; Format = 'json' }).Summary
        "$($budget.Omitted.Kinds)|$($budget.Omitted.Contains('Kept'))|$($budget.Kept.Count)" | Should -BeExactly '3|False|3'
        $tight = (Invoke-TestFilter $definition $long -Settings @{ MaxItems = 20; MaxOutputBytes = 140; Format = 'json' }).Summary
        "$($tight.Omitted.Kinds)|$($tight.Omitted.Kept)|$($tight.Kept -join ',')" | Should -BeExactly '3|2|firstlongkeyname: x'
        $plain = ConvertTo-OPumper2FilterSummary (Invoke-TestFilter (New-TestFilter @{ Id = 'n'; Routes = @('t'); Keep = @('.') }) (1..25 | ForEach-Object { "l$_" })).Report
        $plain.Kept.Count | Should -Be 20
        (Invoke-TestFilter (New-TestFilter @{ Id = 'n'; Routes = @('t') }) @('x')).Summary.Contains('Kept') | Should -BeFalse
    }
}
