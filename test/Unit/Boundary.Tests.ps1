BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Boundary and failure contracts' {
    It 'handles implicit configuration and a route longer than its input' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            Mock Test-Path {$false}
            (Get-OP2Configuration '').MaxItems | Should -Be 20
            Register-OPumper2 -Id long -Route @('long','route','extra') -Handler {} | Out-Null
            (Resolve-OPumper2Command long).Supported | Should -BeFalse
        }
    }
    It 'expands a configured home-relative database path' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            $path=Join-Path $Directory 'home.yaml'
            [IO.File]::WriteAllText($path,"general:`n  databasePath: ~/.opumper2/expanded.sqlite")
            $previous=$script:OP2Environment.OPUMPER2_DB_PATH
            try {$script:OP2Environment.OPUMPER2_DB_PATH='';(Get-OP2Configuration $path).DatabasePath | Should -Be (Join-Path $HOME '.opumper2/expanded.sqlite')}
            finally {$script:OP2Environment.OPUMPER2_DB_PATH=$previous}
        }
    }
    It 'bounds excessive depth and reports an impossible metadata budget' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            Protect-OP2Value @{Value=42} 31 | Should -Be '[DEPTH LIMIT]'
            $completion=New-OP2Completion -Outcome ('x'*1000)
            {ConvertTo-OPumper2Output @($completion) -Format json -MaxOutputBytes 256} | Should -Throw
        }
    }
    It 'kills the tree at the deadline and abandons the streams after the termination grace period' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $run=[pscustomobject]@{Kills=0;Abandons=0}
            $run | Add-Member -MemberType ScriptMethod -Name Kill -Value {$this.Kills++}
            $run | Add-Member -MemberType ScriptMethod -Name Abandon -Value {$this.Abandons++}
            Invoke-OP2Termination $run 1 1
            Invoke-OP2Termination $run 5.9 1
            "$($run.Kills)|$($run.Abandons)" | Should -BeExactly '2|0'
            Invoke-OP2Termination $run 6 1
            "$($run.Kills)|$($run.Abandons)" | Should -BeExactly '3|1'
        }
    }
    It 'fails dependency preparation explicitly' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            Mock Test-Path {$false}
            {Initialize-OP2Dependency} | Should -Throw '*Prepare the native dependency*'
        }
    }
}
