BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
}

Describe 'Call scopes' {
    It 'keeps distinct case-sensitive paths separate and reuses equivalent case-insensitive paths' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            foreach ($sensitive in @($true, $false)) {
                $paths = [Collections.Generic.Dictionary[string,int]]::new((Get-OP2PathComparer -CaseSensitive $sensitive))
                $paths['/data/History.sqlite'] = 1
                $paths['/data/history.sqlite'] = 2
                $paths.Count | Should -Be $(if ($sensitive) { 2 } else { 1 })
            }
        }
    }
    It 'shares a configuration snapshot, refreshes it for a scoped environment, and restores it after failure' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Directory = $TestDrive } {
            $path = Join-Path $Directory 'scope.yaml'
            [IO.File]::WriteAllText($path, "general:`n  maxItems: 7")
            $outerEnvironment = $script:OP2Environment.Clone()
            $outerEnvironment.OPUMPER2_CONFIG_PATH = $path
            Use-OPumper2Environment $outerEnvironment {
                $root = Enter-OP2Call 0
                try {
                    $first = Get-OP2CallConfiguration
                    $first.MaxItems | Should -Be 7
                    [IO.File]::WriteAllText($path, "general:`n  maxItems: 3")
                    $child = Enter-OP2Call 1
                    try { [object]::ReferenceEquals((Get-OP2CallConfiguration), $first) | Should -BeTrue }
                    finally { Exit-OP2Call $child }
                    $innerEnvironment = $outerEnvironment.Clone()
                    $innerEnvironment.OPUMPER2_DB_PATH = Join-Path $Directory 'inner.sqlite'
                    { Use-OPumper2Environment $innerEnvironment {
                        $inner = Enter-OP2Call 2
                        try {
                            $current = Get-OP2CallConfiguration
                            $current.MaxItems | Should -Be 3
                            $current.DatabasePath | Should -Be $innerEnvironment.OPUMPER2_DB_PATH
                            throw 'deliberate child failure'
                        } finally { Exit-OP2Call $inner }
                    } } | Should -Throw '*deliberate child failure*'
                    [object]::ReferenceEquals((Get-OP2CallConfiguration), $first) | Should -BeTrue
                    [object]::ReferenceEquals($script:OP2CurrentCall, $root) | Should -BeTrue
                } finally { Exit-OP2Call $root }
                # A new root sees the changed file; a read outside a call also remains fresh.
                $next = Enter-OP2Call 3
                try { (Get-OP2CallConfiguration).MaxItems | Should -Be 3 } finally { Exit-OP2Call $next }
                (Get-OP2CallConfiguration).MaxItems | Should -Be 3
            }
        }
    }

    It 'restores the parent after a reentrant native callback fails in another database' {
        $outer = Get-TestEnvironment
        $outer.OPUMPER2_DB_PATH = Join-Path $TestDrive 'parent.sqlite'
        $inner = $outer.Clone(); $inner.OPUMPER2_DB_PATH = Join-Path $TestDrive 'child.sqlite'
        $state = @{ InnerEnvironment = $inner; Nested = $null; Seen = 0; Scope = $null }
        Use-OPumper2Environment $outer {
            $result = Invoke-TestChild '"one";"two"' @{ State = $state; OnRecord = {
                param($record, $s)
                if (!$s.Seen) {
                    $s.Scope = & (Get-Module FrenchExDev.OPumper2.PoSh) { $script:OP2CurrentCall }
                    Use-OPumper2Environment $s.InnerEnvironment {
                        $s.Nested = Invoke-TestChild '"child"' @{ OnRecord = { throw 'nested callback failed' } }
                    }
                    $restored = & (Get-Module FrenchExDev.OPumper2.PoSh) { $script:OP2CurrentCall }
                    [object]::ReferenceEquals($restored, $s.Scope) | Should -BeTrue
                }
                $s.Seen++
            } }
            $result.Outcome | Should -Be 'Success'
            $state.Nested.Outcome | Should -Be 'Failed'
            $state.Seen | Should -Be 2
            foreach ($entry in @(@{Path=$outer.OPUMPER2_DB_PATH;Outcome='Success'},@{Path=$inner.OPUMPER2_DB_PATH;Outcome='Failed'})) {
                InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Entry = $entry } {
                    $config = Get-OP2Configuration; $config.DatabasePath = $Entry.Path
                    $rows = @(Invoke-OP2Sql $config 'SELECT outcome FROM invocations;' -Read)
                    $rows.Count | Should -Be 1
                    $rows[0].outcome | Should -Be $Entry.Outcome
                    $null -eq $script:OP2CurrentCall | Should -BeTrue
                }
            }
            $state.Scope.Account.Stores.Count | Should -Be 0
        }
    }

    It 'uses a replaceable UTC clock for history independently of monotonic durations' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Directory = $TestDrive } {
            (Get-OP2UtcNow).Kind | Should -Be 'Utc'
            Mock Get-OP2UtcNow { [DateTime]::new(2026,1,2,3,4,5,[DateTimeKind]::Utc) }
            $config = Get-OP2Configuration; $config.DatabasePath = Join-Path $Directory 'utc.sqlite'
            $result = New-OP2Completion -Execution @{ ExitCode=0; InvocationIds=@('utc'); ElapsedMs=1; StdoutBytes=1; StderrBytes=0 }
            $result.Capture = @{Stdout='x';Stderr='';Complete=$true;Lossy=$false}
            Save-OP2Invocation $result $Directory 'fixture' $config
            @(Invoke-OP2Sql $config "SELECT timestamp FROM invocations WHERE id='utc';" -Read)[0].timestamp | Should -BeExactly '2026-01-02T03:04:05.0000000Z'
        }
    }
}
