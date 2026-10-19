BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Task metadata is independent of assigned domain values' {
    It 'combines exact completeness and truncation flags for one or many steps' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            foreach($case in @(
                @{Source=$true;Analysis=$true;Truncated=$false},
                @{Source=$false;Analysis=$true;Truncated=$false},
                @{Source=$true;Analysis=$false;Truncated=$true},
                @{Source=$false;Analysis=$false;Truncated=$true}
            )) {
                $result=Invoke-OPumper2Task -AsObject -ArgumentList @($case) -ScriptBlock {
                    param($flags)
                    $step=New-OP2Completion
                    $step.Completeness.Source=$flags.Source;$step.Completeness.Analysis=$flags.Analysis;$step.Truncation.Applied=$flags.Truncated
                    Add-OP2Completion $step
                    @{Value=42}
                }
                $result.Data.Value | Should -Be 42
                $result.Completeness.Source | Should -Be $case.Source
                $result.Completeness.Analysis | Should -Be $case.Analysis
                $result.Truncation.Applied | Should -Be $case.Truncated
            }
        }
    }
    It 'filters bare step completions and bounds issues independently of data' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $result=Invoke-OPumper2Task -AsObject -ScriptBlock {
                $step=New-OP2Completion
                Add-OP2Completion $step
                $step
                @{Value=42}
            }
            $result.Data.Value | Should -Be 42
            $result.Execution.Steps | Should -Be 1
            $result.Execution.ElapsedMs | Should -BeGreaterThan 0
            $failed=Invoke-OPumper2Task -AsObject -ScriptBlock {
                1..21 | ForEach-Object {Add-OP2Completion (New-OP2Completion -Outcome Failed)}
            }
            $failed.Execution.Issues.Count | Should -Be 20
            $failed.Completeness.Source | Should -BeFalse
            $failed.Completeness.Analysis | Should -BeFalse
            $failed.Data | Should -BeNullOrEmpty
        }
    }
    It 'reports the first unsuccessful step in chronological order' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            foreach($case in @(
                @{Steps=@('Timeout','Failed');Throw=$false;Expected='Timeout'},
                @{Steps=@('Failed','Timeout');Throw=$false;Expected='Failed'},
                @{Steps=@('Unsupported','Cancelled');Throw=$false;Expected='Unsupported'},
                @{Steps=@('Success','Cancelled','Failed');Throw=$false;Expected='Cancelled'},
                @{Steps=@('Success');Throw=$true;Expected='Failed'},
                @{Steps=@('Timeout');Throw=$true;Expected='Timeout'},
                @{Steps=@('Success','Success');Throw=$false;Expected='Success'}
            )) {
                $result=Invoke-OPumper2Task -AsObject -ArgumentList @($case) -ScriptBlock {
                    param($scenario)
                    foreach($outcome in $scenario.Steps) {Add-OP2Completion (New-OP2Completion -Outcome $outcome)}
                    if($scenario.Throw) {throw 'body'}
                }
                $result.Outcome | Should -Be $case.Expected
                $(if($result.Error){$result.Error.Code}) | Should -Be $(if($case.Throw){'TaskFailed'}else{$null})
                (@($result.Execution.Issues | ForEach-Object Outcome) -join ',') | Should -Be (@($case.Steps | Where-Object {$_ -ne 'Success'}) -join ',')
            }
        }
    }
    It 'carries the exit codes and captures of unsuccessful steps, including nested ones, delivering only excerpts' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $script={
                $step=New-OP2Completion -Outcome Failed -Execution @{ExitCode=3;InvocationIds=@();ElapsedMs=1}
                $step.Capture=@{Stdout='out';Stderr='step failed: token=hidden';Complete=$true;Lossy=$false}
                Add-OP2Completion $step
                $null=Invoke-OPumper2Task -AsObject -ScriptBlock {
                    $inner=New-OP2Completion -Outcome Timeout
                    $inner.Capture=@{Stdout='late';Stderr=$null;Complete=$false;Lossy=$false}
                    Add-OP2Completion $inner
                }
                Add-OP2Completion (New-OP2Completion)
            }
            $result=Invoke-OPumper2Task -AsObject -ScriptBlock $script
            $result.Capture | Should -BeNullOrEmpty
            $result.Execution.Issues.Count | Should -Be 3
            $result.Execution.Issues[0].ExitCode | Should -Be 3
            $result.Execution.Issues[0].Capture.Stderr | Should -Be 'step failed: token=hidden'
            $result.Execution.Issues[1].Capture.Stdout | Should -Be 'late'
            $null -eq $result.Execution.Issues[1].ExitCode | Should -BeTrue
            $result.Execution.Issues[2].Outcome | Should -Be 'Timeout'
            $result.Execution.Issues[2].Capture | Should -BeNullOrEmpty
            $text=Invoke-OPumper2Task -AsJson -ScriptBlock $script
            $text | Should -Not -Match 'hidden|Capture'
            $issues=($text | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Execution.Issues
            $issues.Count | Should -Be 3
            $issues[0].ExitCode | Should -Be 3
            ($issues[0].Excerpt.Stderr.Tail -join '|') | Should -BeExactly 'step failed: token=[REDACTED]'
            ($issues[1].Excerpt.Stdout.Tail -join '|') | Should -BeExactly 'late'
            $issues[1].Excerpt.Complete | Should -BeFalse
            $issues[2].ContainsKey('Excerpt') | Should -BeFalse
            $text=Invoke-OPumper2Task -AsJson -ExcerptLines 0 -ScriptBlock $script
            $text | Should -Not -Match 'Excerpt'
        }
    }
    It 'honors configured and explicit task presentation limits' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            $path=Join-Path $Directory 'task-limits.yaml'
            [IO.File]::WriteAllText($path,"general:`n  maxItems: 1`n  excerptLines: 2")
            $before=$script:OP2Environment.OPUMPER2_CONFIG_PATH
            try {
                $script:OP2Environment.OPUMPER2_CONFIG_PATH=$path
                $text=Invoke-OPumper2Task -AsJson -MaxItems 0 -ScriptBlock {@{Answer=42}}
                ($text | ConvertFrom-Json -NoEnumerate)[0].Data.Answer | Should -Be 42
                $failure=Invoke-OPumper2Task -AsObject -ScriptBlock {Write-Information 'fixture' -InformationAction Continue}
                $failure.Completeness.Analysis | Should -BeFalse
                Mock ConvertTo-OPumper2Output {'fixture'}
                Invoke-OPumper2Task -AsJson -MaxItems 0 -ExcerptLines 0 -ScriptBlock {42} | Out-Null
                Should -Invoke ConvertTo-OPumper2Output -Exactly -Times 1 -ParameterFilter {$MaxItems -eq 0 -and $ExcerptLines -eq 0}
                Should -Invoke ConvertTo-OPumper2Output -Exactly -Times 0 -ParameterFilter {$MaxItems -eq 1}
                Invoke-OPumper2Task -AsJson -ScriptBlock {42} | Out-Null
                Should -Invoke ConvertTo-OPumper2Output -Exactly -Times 1 -ParameterFilter {$MaxItems -eq 0}
                Should -Invoke ConvertTo-OPumper2Output -Exactly -Times 1 -ParameterFilter {$MaxItems -eq 1 -and $ExcerptLines -eq 2}
            } finally {$script:OP2Environment.OPUMPER2_CONFIG_PATH=$before}
        }
    }
}
