# The shared suite of a pump module's catalogue. Each module's test/Unit/Catalogue.Tests.ps1 sets, at discovery,
# $CatalogueCase = @{ Name; Root (the module folder); Register (its Register-<Name>OPumper2, or $null when the module
# tests its own registration); RequireAll (every filter must carry a test) } and dot-sources this file.
Describe '<Name> catalogue' -ForEach @($CatalogueCase) {
    BeforeAll {
        $script:Catalogue = Join-Path $Root 'filters'
        $leaf = Split-Path $Root -Leaf
        Get-Module 'FrenchExDev.OPumper2*.PoSh' -All | Remove-Module -Force
        Import-Module (Join-Path (Split-Path $Root) 'FrenchExDev.OPumper2.PoSh/FrenchExDev.OPumper2.PoSh.psd1') -Global -Force -DisableNameChecking
        Import-Module (Join-Path $Root "$leaf.psd1") -Global -Force
        # A short engine timeout, and a measurement database and configuration of the run's own: parallel runspaces
        # share the process environment, so the engine reads a runspace-local substitute.
        $configuration = Join-Path $TestDrive 'catalogue-test-configuration.yaml'
        [IO.File]::WriteAllText($configuration, "general:`n  timeoutSeconds: 20")
        Use-OPumper2Environment @{ OPUMPER2_DB_PATH = (Join-Path $TestDrive 'catalogue-measurements.sqlite'); OPUMPER2_CONFIG_PATH = $configuration }
    }
    It 'passes the tests built into its filters' {
        $results = @(Test-OPumper2Filter -Path $script:Catalogue -RequireAll:$RequireAll)
        @($results | Where-Object { !$_.Passed } | ForEach-Object { "$($_.Filter)/$($_.Test): $($_.Failures -join '; ')" }) | Should -BeNullOrEmpty
        # A filter that keeps lines shows both a successful and a failed run.
        @($results | Where-Object { $_.Warnings } | ForEach-Object { "$($_.Filter): $($_.Warnings -join ', ')" } | Select-Object -Unique) | Should -BeNullOrEmpty
        @($results | Where-Object { !$_.Untested }).Count | Should -BeGreaterThan 0
    }
    It 'holds filters with distinct routes that say what they deliver and which output format they follow' {
        $definitions = @(Get-OPumper2Filter -Path $script:Catalogue)
        $definitions.Count | Should -BeGreaterThan 0
        @($definitions.Routes | Group-Object | Where-Object Count -GT 1).Count | Should -Be 0
        foreach ($definition in $definitions) {
            "$($definition.Id): $([bool]$definition.Description) $([bool]$definition.Source)" | Should -BeExactly "$($definition.Id): True True"
        }
    }
    It 'is documented by the generated catalogue page' {
        $page = [IO.File]::ReadAllText((Join-Path $Root 'doc/CATALOGUE.md'))
        ConvertTo-OPumper2FilterCatalogue @(Get-OPumper2Filter -Path $script:Catalogue) | Should -BeExactly $page -Because 'doc/CATALOGUE.md is regenerated with ConvertTo-OPumper2FilterCatalogue'
    }
    # A module that tests its own registration (Register = $null) gets no registration case, rather than a skipped one.
    Context 'registration' -AllowNullOrEmptyForEach -ForEach @(@($CatalogueCase) | Where-Object { $_['Register'] }) {
        It 'registers every route that no contributor registered first' {
            $definitions = @(Get-OPumper2Filter -Path $script:Catalogue)
            $taken = $definitions[0].Routes[0]
            Register-OPumper2 -Id 'catalogue.taken' -Route @($taken -split '\s+') -Handler { param($call) } -ProviderId tests | Out-Null
            $registered = @()
            try {
                $registered = @(& $Register)
                $registered.Count | Should -Be (@($definitions.Routes).Count - 1)
                foreach ($route in @($definitions.Routes)) {
                    $tokens = @($route -split '\s+')
                    $expected = $(if ($route -eq $taken) { 'tests' } else { 'filters' })
                    "$route=$((Resolve-OPumper2Command $tokens[0] @($tokens | Select-Object -Skip 1)).ProviderId)" | Should -BeExactly "$route=$expected"
                }
                # Registering again has no effect; a higher priority takes the route the other contributor held.
                (@(& $Register) | ForEach-Object Id) -join ',' | Should -BeExactly (($registered | ForEach-Object Id) -join ',')
                $registered = @(& $Register -Priority 1)
                $taking = @($registered | Where-Object { $_.PSObject.Properties['Replaced'] })
                "$($taking.Count)|$($taking[0].Replaced)" | Should -BeExactly '1|catalogue.taken'
                $tokens = @($taken -split '\s+')
                (Resolve-OPumper2Command $tokens[0] @($tokens | Select-Object -Skip 1)).ProviderId | Should -BeExactly 'filters'
            } finally {
                Unregister-OPumper2 'catalogue.taken' | Out-Null
                foreach ($entry in $registered) { Unregister-OPumper2 $entry.Id | Out-Null }
            }
        }
    }
}
