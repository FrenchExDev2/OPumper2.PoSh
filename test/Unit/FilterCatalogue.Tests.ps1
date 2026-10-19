BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

# The catalogues themselves, their samples and pages are tested by the ecosystem modules that ship them.
Describe 'Catalogue pages' {
    It 'render escaped cells, counted routes and sections in table order' {
        $definitions = @((New-TestFilter @{ Id = 'z'; Routes = @('tool a', 'tool b'); Description = 'one|two'; Source = 'src'; Counters = @{ C = 'x' }; Captures = @{ P = 'y' }; Groups = @{ G = '(?<key>k)' }; Keep = @('k') }),
            (New-TestFilter @{ Id = 'a'; Routes = @('other') }))
        $page = ConvertTo-OPumper2FilterCatalogue $definitions
        $page | Should -Match '2 filters, 3 routes\.'
        $rows = @($page -split "`n" | Where-Object { $_ -match '^\| `' })
        $rows[0] | Should -BeExactly '| `a` | `other` |  |  |  |'
        $rows[1] | Should -BeExactly '| `z` | `tool a`, `tool b` | one\|two | C, P, G, Kept | src |'
    }
}
