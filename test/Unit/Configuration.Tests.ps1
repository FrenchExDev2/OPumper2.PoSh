BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Configuration and output controls' {
    It 'accepts inclusive presentation boundaries and ignores false output switches' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            $path=Join-Path $Directory 'boundaries.yaml'
            [IO.File]::WriteAllText($path,"general:`n  maxItems: 0`n  maxOutputBytes: 256`n  timeoutSeconds: 1`n  excerptLines: 0")
            $c=Get-OP2Configuration $path
            $c.MaxItems | Should -Be 0
            $c.MaxOutputBytes | Should -Be 256
            $c.TimeoutSeconds | Should -Be 1
            $c.ExcerptLines | Should -Be 0
            Get-OP2Format @{AsJson=$false} $c | Should -Be 'yaml'
            Get-OP2Format @{AsJson=$false;AsObject=$true} $c | Should -Be 'object'
            [IO.File]::WriteAllText($path,'[]')
            {Get-OP2Configuration $path} | Should -Throw '*mapping of sections*'
            [IO.File]::WriteAllText($path,'general')
            {Get-OP2Configuration $path} | Should -Throw '*mapping of sections*'
            [IO.File]::WriteAllText($path,"general: 3")
            {Get-OP2Configuration $path} | Should -Throw '*general section must be a mapping*'
            [IO.File]::WriteAllText($path,"general:`n  maxItems: 1`nroutes: []")
            {Get-OP2Configuration $path} | Should -Throw '*Unknown configuration section: routes*'
        }
    }
    It 'reads ~/.opumper2/config.yaml by default, with or without a general section next to its pumps' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            $path=Join-Path $Directory 'pumps.yaml'
            [IO.File]::WriteAllText($path,"pumps:`n  - name: git`n    path: C:\x`n    enabled: true")
            (Get-OP2Configuration $path).MaxItems | Should -Be 20
            [IO.File]::WriteAllText($path,"general:`n  maxItems: 4`npumps: []")
            (Get-OP2Configuration $path).MaxItems | Should -Be 4
            $default = Join-Path $HOME '.opumper2/config.yaml'
            $previous = $script:OP2Environment.OPUMPER2_CONFIG_PATH
            try {
                $script:OP2Environment.OPUMPER2_CONFIG_PATH = ''
                Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $default }
                Mock Read-OP2ConfigurationDocument { @{ general = @{ maxItems = 3 } } } -ParameterFilter { $Path -eq $default }
                (Get-OP2Configuration).MaxItems | Should -Be 3
            } finally { $script:OP2Environment.OPUMPER2_CONFIG_PATH = $previous }
        }
    }
    It 'uses the documented defaults and environment database path' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            # The suite's own configuration shortens the timeout; defaults are read without any file.
            $config = Get-OP2Configuration (Join-Path $Directory 'absent.yaml')
            $config.OutputFormat | Should -Be 'yaml'
            $config.MaxItems | Should -Be 20
            $config.MaxOutputBytes | Should -Be 8192
            $config.TimeoutSeconds | Should -Be 600
            $config.ExcerptLines | Should -Be 20
            $config.DatabasePath | Should -Be $script:OP2Environment.OPUMPER2_DB_PATH
            $config.RetentionDays | Should -Be 90
            $config.RecallWindowMinutes | Should -Be 30
            $config.MeasureAlternateFormat | Should -BeFalse
            $config.SessionVariable | Should -BeExactly 'OPUMPER2_SESSION'
            $config.TokenPrice | Should -BeNullOrEmpty
            $config.Currency | Should -BeExactly 'USD'
            $config.MonthlyTokenBudget | Should -BeNullOrEmpty
            $config.QuotaTiers.Count | Should -Be 0
            $config.QuotaTier | Should -BeNullOrEmpty
            $config.Tracking | Should -BeTrue
            $config.Envelope | Should -BeExactly 'full'
            "$($config.Recall)|$($config.RecallRetentionDays)|$($config.RecallMaxEntries)|$($config.RecallMaxEntryBytes)|$($config.RecallMask)" | Should -BeExactly 'on|30|200|10485760|True'
            "$($config.HookAwareness)|$(@($config.HookExcludeCommands).Count)" | Should -BeExactly 'warn|0'
            (Get-OPumper2Configuration).Recall | Should -BeExactly 'on'
            foreach ($pair in @(@('OPUMPER2_TRACKING','0','False|on|warn'),@('OPUMPER2_RECALL','0','True|off|warn'),@('OPUMPER2_HOOK','0','True|on|off'),@('OPUMPER2_TRACKING','1','True|on|warn'))) {
                $previous=$script:OP2Environment[$pair[0]]
                try {
                    $script:OP2Environment[$pair[0]]=$pair[1]
                    $switched=Get-OP2Configuration (Join-Path $Directory 'absent.yaml')
                    "$($switched.Tracking)|$($switched.Recall)|$($switched.HookAwareness)" | Should -BeExactly $pair[2]
                } finally { $script:OP2Environment[$pair[0]]=$previous }
            }
            $saved=$script:OP2Environment
            try {
                # Without a substitute the module reads the process environment, which no test writes.
                $script:OP2Environment=$null
                Get-OP2EnvironmentValue 'PATH' | Should -Be ([Environment]::GetEnvironmentVariable('PATH'))
                Get-OP2EnvironmentValue 'OP2_UNSET_FIXTURE_VARIABLE' | Should -BeNullOrEmpty
            } finally {$script:OP2Environment=$saved}
            Get-OP2Format @{} $config | Should -Be 'yaml'
            Get-OP2Format @{AsObject=$true} $config | Should -Be 'object'
            Get-OP2Format @{AsJson=$true} $config | Should -Be 'json'
            Get-OP2Format @{AsYaml=$true} $config | Should -Be 'yaml'
            Get-OP2Format @{AsText=$true} $config | Should -Be 'text'
            Get-OP2Format @{AsCsv=$true} $config | Should -Be 'csv'
            Get-OP2Format @{AsLine=$true} $config | Should -Be 'line'
            { Get-OP2Format @{AsYaml=$true;AsJson=$true} $config } | Should -Throw
            { Get-OP2Format @{AsCsv=$true;AsLine=$true} $config } | Should -Throw '*mutually exclusive*'
        }
    }
    It 'reads general configuration and rejects invalid documents' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            $path = Join-Path $Directory 'config.yaml'
            foreach ($invalid in @('other: true',"general:`n  missing: true","general:`n  outputFormat: wrong","general:`n  maxItems: -1","general:`n  maxOutputBytes: 1","general:`n  timeoutSeconds: 0","general:`n  excerptLines: -1")) {
                [IO.File]::WriteAllText($path,$invalid)
                { Get-OP2Configuration $path } | Should -Throw
            }
            [IO.File]::WriteAllText($path,"general:`n  outputFormat: json`n  maxItems: 5`n  databasePath: ~/.opumper2/custom.sqlite")
            (Get-OP2Configuration $path).OutputFormat | Should -Be 'json'
            (Get-OP2Configuration $path).MaxItems | Should -Be 5
            foreach ($invalid in @("general:`n  envelope: tiny","general:`n  recall: sometimes","general:`n  hookAwareness: loud")) {
                [IO.File]::WriteAllText($path,$invalid)
                { Get-OP2Configuration $path } | Should -Throw '*envelope, recall or hook awareness*'
            }
            foreach ($valid in @('envelope: compact','recall: failures','recall: off','hookAwareness: off','hookAwareness: deny','hookAwareness: rewrite','recallMaxEntries: 0','recallRetentionDays: 0','recallMaxEntryBytes: 1')) {
                [IO.File]::WriteAllText($path,"general:`n  $valid")
                { Get-OP2Configuration $path } | Should -Not -Throw
            }
            foreach ($invalid in @("general:`n  retentionDays: -1","general:`n  recallWindowMinutes: -1","general:`n  recallRetentionDays: -1","general:`n  recallMaxEntries: -1","general:`n  recallMaxEntryBytes: 0")) {
                [IO.File]::WriteAllText($path,$invalid)
                { Get-OP2Configuration $path } | Should -Throw '*measurement history setting*'
            }
            [IO.File]::WriteAllText($path,"general:`n  retentionDays: 0`n  recallWindowMinutes: 0`n  measureAlternateFormat: true`n  tokenPrice: 2.5`n  currency: EUR`n  monthlyTokenBudget: 1000000`n  sessionVariable: AGENT_SESSION")
            $history=Get-OP2Configuration $path
            $history.RetentionDays | Should -Be 0
            $history.RecallWindowMinutes | Should -Be 0
            $history.MeasureAlternateFormat | Should -BeTrue
            $history.TokenPrice | Should -Be 2.5
            $history.Currency | Should -BeExactly 'EUR'
            $history.MonthlyTokenBudget | Should -Be 1000000
            $history.SessionVariable | Should -BeExactly 'AGENT_SESSION'
        }
    }
    It 'gives the engine an environment of its own, for a block or until the next call' {
        $saved = InModuleScope FrenchExDev.OPumper2.PoSh { $script:OP2Environment }
        $read = { param($name) InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Name = $name } { Get-OP2EnvironmentValue $Name } }
        try {
            $source = @{ OPUMPER2_DB_PATH = 'a.sqlite' }
            Use-OPumper2Environment $source | Should -BeNullOrEmpty
            # A copy: the caller's later changes do not reach the engine.
            $source.OPUMPER2_DB_PATH = 'changed'
            & $read OPUMPER2_DB_PATH | Should -BeExactly 'a.sqlite'
            # For a block, that environment alone, and its output.
            Use-OPumper2Environment @{ OPUMPER2_TRACKING = '0' } { "$(& $read OPUMPER2_TRACKING)|$(& $read OPUMPER2_DB_PATH)" } | Should -BeExactly '0|'
            & $read OPUMPER2_DB_PATH | Should -BeExactly 'a.sqlite'
            { Use-OPumper2Environment @{ OPUMPER2_DB_PATH = 'b.sqlite' } { throw 'fixture' } } | Should -Throw 'fixture'
            & $read OPUMPER2_DB_PATH | Should -BeExactly 'a.sqlite'
            # Reset returns to the process environment.
            Use-OPumper2Environment -Reset
            InModuleScope FrenchExDev.OPumper2.PoSh { $null -eq $script:OP2Environment } | Should -BeTrue
        } finally { InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Saved = $saved } { $script:OP2Environment = $Saved } }
    }
    It 'rejects conflicting callbacks and invalid limits before execution' {
        { Pump-Me nothing -OnRecord {} -OnStdOut {} -AsObject } | Should -Throw
        { Pump-Me nothing -OnRecord {} -TimeoutSeconds 0 -AsObject } | Should -Throw
        { Pump-Me nothing -OnRecord {} -MaxItems -1 -AsObject } | Should -Throw
        { Pump-Me nothing -OnRecord {} -MaxOutputBytes 1 -AsObject } | Should -Throw
        { Pump-Me nothing -OnRecord {} -ExcerptLines -1 -AsObject } | Should -Throw '*presentation limit*'
    }
    It 'validates task limits before the task body and accepts explicit zero item and excerpt limits' {
        $state = @{ Ran = $false }
        $body = { param($s) $s.Ran = $true; 'value' }
        foreach ($limit in @(@{ MaxItems = -1 }, @{ MaxOutputBytes = 255 }, @{ ExcerptLines = -1 })) {
            { Invoke-OPumper2Task $body -ArgumentList $state -AsObject @limit } | Should -Throw '*presentation limit*'
        }
        $state.Ran | Should -BeFalse
        $result = Invoke-OPumper2Task $body -ArgumentList $state -MaxItems 0 -ExcerptLines 0 -AsObject
        "$($result.Outcome)|$($result.Data)|$($state.Ran)" | Should -BeExactly 'Success|value|True'
    }
    It 'uses a supplied delivery configuration without reading configuration again' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $configuration = Get-OP2Configuration
            $configuration.Tracking = $false
            $configuration.OutputFormat = 'json'
            Mock Get-OP2Configuration { throw 'Unexpected configuration read.' }
            # ConvertTo-OPumper2Output keeps its explicit/default format; the configuration supplies its limits.
            $values = @('first', 'second', (New-OP2Completion))
            $json = ConvertTo-OPumper2Output $values -Format json -Configuration $configuration -MaxItems 0 -ExcerptLines 0 | ConvertFrom-Json -AsHashtable -NoEnumerate
            $json.Count | Should -Be 1
            $json[0].Truncation.OmittedRecords | Should -Be 2
            $json[0].Truncation.Reasons | Should -Contain 'ItemLimit'
            (ConvertTo-OPumper2Output @((New-OP2Completion)) -Configuration $configuration) | Should -Match 'Kind: Completion'
            Should -Invoke Get-OP2Configuration -Times 0
        }
    }
}
