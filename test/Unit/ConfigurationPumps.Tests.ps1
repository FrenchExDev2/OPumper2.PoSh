BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    function New-TestPumpFolder {
        # Module folders next to each other, as a checkout holds them; a src folder marks a dedicated contract.
        param([string]$Root, [string[]]$Name, [string[]]$WithSource = @())
        foreach ($item in $Name) { [void][IO.Directory]::CreateDirectory((Join-Path $Root $item)) }
        foreach ($item in $WithSource) { [void][IO.Directory]::CreateDirectory((Join-Path $Root "$item/src")) }
    }
}

Describe 'Pumps configuration' {
    It 'locates the file from OPUMPER2_CONFIG_PATH, or next to the measurement database' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $previous = $script:OP2Environment.OPUMPER2_CONFIG_PATH
            try {
                $script:OP2Environment.OPUMPER2_CONFIG_PATH = 'C:\custom.yaml'
                Get-OP2ConfigurationPath | Should -BeExactly 'C:\custom.yaml'
                $script:OP2Environment.OPUMPER2_CONFIG_PATH = ''
                Get-OP2ConfigurationPath | Should -BeExactly (Join-Path $HOME '.opumper2/config.yaml')
            } finally { $script:OP2Environment.OPUMPER2_CONFIG_PATH = $previous }
        }
    }
    It 'validates each entry and names it in errors' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Directory = $TestDrive } {
            foreach ($case in @(
                @('x', '*pumps`[3`] must be a mapping*'), @(@{ name = 'a'; path = 'p'; colour = 1 }, "*pumps``[3``]: unknown key 'colour'*"),
                @(@{ path = 'p' }, '*pumps`[3`] needs a name*'), @(@{ name = 'a' }, '*pumps`[3`] (a) needs exactly one of path and module*'),
                @(@{ name = 'a'; path = 'p'; module = 'm' }, '*exactly one of path and module*'), @(@{ name = 'a'; path = 'p'; enabled = 'yes' }, '*(a): enabled must be true or false*'),
                @(@{ name = 'a'; path = 'p'; priority = 1.5 }, '*(a): priority must be an integer*'))) {
                { ConvertTo-OP2PumpEntry $case[0] 3 } | Should -Throw $case[1]
            }
            $defaults = ConvertTo-OP2PumpEntry @{ name = 'git'; path = $Directory } 0
            "$($defaults.Name)|$($defaults.Enabled)|$($defaults.Priority)|$($defaults.Exists)|$($defaults.PSObject.TypeNames[0])" | Should -BeExactly 'git|True|0|True|OPumper2.Pump'
            $missing = ConvertTo-OP2PumpEntry @{ name = 'old'; path = (Join-Path $Directory 'none'); enabled = $false; priority = 7 } 0
            "$($missing.Enabled)|$($missing.Priority)|$($missing.Exists)" | Should -BeExactly 'False|7|False'
            (ConvertTo-OP2PumpEntry @{ name = 'pester'; module = 'Pester' } 0).Exists | Should -BeTrue
            (ConvertTo-OP2PumpEntry @{ name = 'none'; module = 'OP2.Missing.Module' } 0).Exists | Should -BeFalse
        }
    }
    It 'reads the pumps in file order, none without a file or a section, and refuses a malformed list' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Directory = $TestDrive } {
            $path = Join-Path $Directory 'read.yaml'
            @(Read-OP2PumpList $path).Count | Should -Be 0
            [IO.File]::WriteAllText($path, "general:`n  maxItems: 3")
            @(Read-OP2PumpList $path).Count | Should -Be 0
            [IO.File]::WriteAllText($path, "pumps:`n  - name: b`n    module: B`n  - name: a`n    path: $Directory")
            (@(Read-OP2PumpList $path) | ForEach-Object Name) -join ',' | Should -BeExactly 'b,a'
            [IO.File]::WriteAllText($path, "pumps:`n  - name: a`n    module: A`n  - name: A`n    module: B")
            { Read-OP2PumpList $path } | Should -Throw "*pumps``[1``]: duplicate name 'A'*"
            [IO.File]::WriteAllText($path, "pumps: {a: 1}")
            { Read-OP2PumpList $path } | Should -Throw '*pumps section must be a list*'
            [IO.File]::WriteAllText($path, "routes: []")
            { Read-OP2PumpList $path } | Should -Throw '*Unknown configuration section*'
        }
    }
    It 'adds, lists, disables, enables and removes pumps, keeping the general settings' {
        $config = Join-Path $TestDrive 'nested/config.yaml'
        $folder = Join-Path $TestDrive 'FrenchExDev.OPumper2.Git.PoSh'; [void][IO.Directory]::CreateDirectory($folder)
        $added = Add-OPumper2Pump -Name git -Path $folder -Priority 5 -ConfigurationPath $config
        "$($added.Name)|$($added.Path)|$($added.Priority)|$($added.Enabled)" | Should -BeExactly "git|$folder|5|True"
        [IO.File]::WriteAllText($config, ([IO.File]::ReadAllText($config) -replace '^', "general:`n  maxItems: 9`n  envelope: compact`n"))
        Add-OPumper2Pump -Name pester -Module Pester -Disabled -ConfigurationPath $config | Out-Null
        { Add-OPumper2Pump -Name GIT -Module X -ConfigurationPath $config } | Should -Throw "*A pump named 'GIT' already exists*"
        (Get-OPumper2Pump -ConfigurationPath $config | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ',' | Should -BeExactly 'git=True,pester=False'
        (Get-OPumper2Pump -Name 'pe*' -ConfigurationPath $config).Module | Should -BeExactly 'Pester'
        Disable-OPumper2Pump -Name git -ConfigurationPath $config
        Enable-OPumper2Pump -Name pester -ConfigurationPath $config
        (Get-OPumper2Pump -ConfigurationPath $config | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ',' | Should -BeExactly 'git=False,pester=True'
        $text = [IO.File]::ReadAllText($config)
        $text | Should -Match '(?m)^general:\r?\n  envelope: compact\r?\n  maxItems: 9'
        # Only a non-zero priority is written.
        ([regex]::Matches($text, '(?m)^\s+priority: 5\r?$')).Count | Should -Be 1
        ([regex]::Matches($text, 'priority:')).Count | Should -Be 1
        Remove-OPumper2Pump -Name pester -ConfigurationPath $config
        (Get-OPumper2Pump -ConfigurationPath $config).Name | Should -BeExactly 'git'
        { Remove-OPumper2Pump -Name pester -ConfigurationPath $config } | Should -Throw "*No pump named 'pester'*"
        { Enable-OPumper2Pump -Name none -ConfigurationPath $config } | Should -Throw "*No pump named 'none'*"
        # WhatIf changes nothing.
        $before = [IO.File]::ReadAllText($config)
        Add-OPumper2Pump -Name x -Module X -ConfigurationPath $config -WhatIf | Out-Null
        Remove-OPumper2Pump -Name git -ConfigurationPath $config -WhatIf
        Disable-OPumper2Pump -Name git -ConfigurationPath $config -WhatIf
        Enable-OPumper2Pump -Name git -ConfigurationPath $config -WhatIf
        [IO.File]::ReadAllText($config) | Should -BeExactly $before
        (Get-Command Add-OPumper2Pump).Module.Name | Should -BeExactly 'FrenchExDev.OPumper2.PoSh'
    }
    It 'creates the configuration from the pump modules found, dedicated contracts first, never over an existing file by default' {
        $root = Join-Path $TestDrive 'checkout'
        New-TestPumpFolder $root @('FrenchExDev.OPumper2.Search.PoSh', 'FrenchExDev.OPumper2.Git.PoSh', 'FrenchExDev.OPumper2.Utility.Agent.PoSh', 'FrenchExDev.OPumper2.Node.PoSh', 'FrenchExDev.OPumper2.PoSh') -WithSource @('FrenchExDev.OPumper2.Git.PoSh')
        $config = Join-Path $TestDrive 'created/config.yaml'
        New-OPumper2Configuration -Path $config -ModuleRoot $root -WhatIf | Out-Null
        Test-Path -LiteralPath $config | Should -BeFalse
        $created = @(New-OPumper2Configuration -Path $config -ModuleRoot $root)
        ($created | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ',' | Should -BeExactly 'git=True,node=True,search=True'
        # The file is UTF-8 without a byte-order mark.
        [IO.File]::ReadAllBytes($config)[0] | Should -Not -Be 0xEF
        (Get-OPumper2Pump -ConfigurationPath $config | ForEach-Object Name) -join ',' | Should -BeExactly 'git,node,search'
        { New-OPumper2Configuration -Path $config -ModuleRoot $root } | Should -Throw '*already exists; use -Force*'
        Remove-Item -LiteralPath (Join-Path $root 'FrenchExDev.OPumper2.Node.PoSh')
        @(New-OPumper2Configuration -Path $config -ModuleRoot $root -Force).Count | Should -Be 2
        @(Get-OPumper2Pump -ConfigurationPath $config).Count | Should -Be 2
    }
    It 'proposes a repair for each missing folder, and writes it only with Apply' {
        $root = Join-Path $TestDrive 'repair'
        New-TestPumpFolder $root @('FrenchExDev.OPumper2.Node.PoSh', 'FrenchExDev.OPumper2.Containers.PoSh', 'FrenchExDev.OPumper2.Make.PoSh')
        $config = Join-Path $TestDrive 'repair.yaml'
        # Paths of the running system: a backslash is part of a file name on Linux.
        $in = { param($name) Join-Path $root $name }
        $lines = @('pumps:',
            "  - {name: pnpm, path: '$(& $in 'FrenchExDev.Pnpm.OPumper2.PoSh')', enabled: true}",
            "  - {name: containers, path: '$(& $in 'FrenchExDev.OPumper2.Containers.PoSh')', enabled: true}",
            "  - {name: podman, path: '$(& $in 'FrenchExDev.Podman.OPumper2.PoSh')', enabled: true}",
            "  - {name: build, path: '$(& $in 'FrenchExDev.OPumper2.Build.PoSh')', enabled: true}",
            "  - {name: powershell, path: '$(& $in 'FrenchExDev.Powershell.OPumper2.PoSh')', enabled: true}",
            "  - {name: old, path: '$(& $in 'Elsewhere')', enabled: false}",
            "  - {name: pester, module: Pester}")
        [IO.File]::WriteAllText($config, ($lines -join "`n"))
        $proposed = @(Repair-OPumper2Configuration -ConfigurationPath $config)
        ($proposed | ForEach-Object { "$($_.Name):$($_.Action):$($_.Reason)" }) -join ',' | Should -BeExactly 'pnpm:Repath:Renamed,podman:Remove:AlreadyConfigured,build:Repath:Renamed,powershell:Disable:NoReplacement,old:None:NoReplacement'
        $proposed[0].Path | Should -BeExactly (Join-Path $root 'FrenchExDev.OPumper2.Node.PoSh')
        [IO.File]::ReadAllText($config) | Should -Match 'Pnpm'
        Repair-OPumper2Configuration -ConfigurationPath $config -Apply -WhatIf | Out-Null
        [IO.File]::ReadAllText($config) | Should -Match 'Pnpm'
        Repair-OPumper2Configuration -ConfigurationPath $config -Apply | Out-Null
        $after = @(Get-OPumper2Pump -ConfigurationPath $config)
        ($after | ForEach-Object { "$($_.Name)=$($_.Enabled)/$($_.Exists)" }) -join ',' | Should -BeExactly 'pnpm=True/True,containers=True/True,build=True/True,powershell=False/False,old=False/False,pester=True/True'
        @(Repair-OPumper2Configuration -ConfigurationPath $config -Apply | Where-Object Action -notin @('None', 'Disable')).Count | Should -Be 0
        $clean = Join-Path $TestDrive 'clean.yaml'; [IO.File]::WriteAllText($clean, "pumps:`n  - {name: node, path: '$(& $in 'FrenchExDev.OPumper2.Node.PoSh')'}")
        $stamp = (Get-Item $clean).LastWriteTimeUtc
        @(Repair-OPumper2Configuration -ConfigurationPath $clean -Apply).Count | Should -Be 0
        (Get-Item $clean).LastWriteTimeUtc | Should -Be $stamp
    }
}
