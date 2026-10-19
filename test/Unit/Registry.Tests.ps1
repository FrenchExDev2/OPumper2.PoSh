BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Public positional command contracts' {
    It 'declares the binary before its remaining arguments' {
        foreach($name in @('Pump-Me','Resolve-OPumper2Command')) {
            $command=Get-Command $name
            ($command.Parameters.Command.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute]}).Position | Should -Contain 0
            ($command.Parameters.ArgumentList.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute]}).Position | Should -Contain 1
        }
    }
}

Describe 'Registry' {
    BeforeEach { InModuleScope FrenchExDev.OPumper2.PoSh { $script:OP2Routes.Clear() } }
    It 'does not execute an unsupported route' {
        $result = Pump-Me not-an-executable anything -AsObject
        $result.Outcome | Should -Be 'Unsupported'
        $result.Error.Code | Should -Be 'RouteNotFound'
        (Resolve-OPumper2Command not-an-executable anything).Supported | Should -BeFalse
    }
    It 'matches the longest prefix, rejects duplicates and removes routes' {
        Register-OPumper2 -Id parent -Route @('tool') -Handler {} | Out-Null
        Register-OPumper2 -Id child -Route @('tool','status') -ProviderId example -Handler {} | Out-Null
        (Resolve-OPumper2Command tool status).Id | Should -Be 'child'
        (Resolve-OPumper2Command tool other).Id | Should -Be 'parent'
        (Resolve-OPumper2Command other status).Supported | Should -BeFalse
        { Register-OPumper2 -Id child -Route @('other') -Handler {} } | Should -Throw
        { Register-OPumper2 -Id other -Route @('tool') -Handler {} } | Should -Throw
        { Register-OPumper2 -Id empty -Route @(' ') -Handler {} } | Should -Throw
        Unregister-OPumper2 child | Should -BeTrue
        Unregister-OPumper2 child | Should -BeFalse
        (Resolve-OPumper2Command tool status).Id | Should -Be 'parent'
    }
    It 'registers the same route again without effect, and gives a taken route to a higher priority only' {
        $first = Register-OPumper2 -Id tool.run -Route @('tool','run') -Handler { 'first' } -ProviderId one
        "$($first.Id)|$($first.ProviderId)|$($first.Priority)|$($null -eq $first.PSObject.Properties['Replaced'])" | Should -BeExactly 'tool.run|one|0|True'
        # Same Id, route and provider: nothing changes, not even the handler.
        (Register-OPumper2 -Id tool.run -Route @('TOOL','run') -Handler { 'second' } -ProviderId one).Id | Should -BeExactly 'tool.run'
        InModuleScope FrenchExDev.OPumper2.PoSh { & $script:OP2Routes["tool`0run"].Handler } | Should -BeExactly 'first'
        { Register-OPumper2 -Id tool.run -Route @('tool','run') -Handler {} -ProviderId two } | Should -Throw '*Duplicate*'
        # Another Id: an equal or lower priority is refused, a higher one takes the route.
        { Register-OPumper2 -Id other.run -Route @('tool','run') -Handler {} -Priority 0 } | Should -Throw '*Duplicate*'
        { Register-OPumper2 -Id other.run -Route @('tool','run') -Handler {} -Priority -1 } | Should -Throw '*Duplicate*'
        $taken = Register-OPumper2 -Id other.run -Route @('tool','run') -Handler {} -ProviderId two -Priority 5
        "$($taken.Replaced)|$($taken.Priority)" | Should -BeExactly 'tool.run|5'
        $resolved = Resolve-OPumper2Command tool run x
        "$($resolved.Id)|$($resolved.ProviderId)|$($resolved.Priority)" | Should -BeExactly 'other.run|two|5'
        $null -eq (Resolve-OPumper2Command nothing).Priority | Should -BeTrue
        InModuleScope FrenchExDev.OPumper2.PoSh { "$(Get-OP2RoutePriority @('tool','run'))|$($null -eq (Get-OP2RoutePriority @('none')))" } | Should -BeExactly '5|True'
    }
    It 'gives a filter route to a higher priority, and registers a catalogue again without effect' {
        $catalogue = Join-Path $TestDrive 'priority'; [void][IO.Directory]::CreateDirectory($catalogue)
        [IO.File]::WriteAllText((Join-Path $catalogue 'p.psd1'), "@{ Filters = @(@{ Id = 'p.one'; Routes = @('ptool one', 'ptool two'); Description = 'd'; Source = 's'; Tests = @(@{ Name = 'n'; Expect = @{ Lines = '0' } }) }) }")
        Register-OPumper2 -Id held -Route @('ptool','two') -Handler {} -ProviderId tests | Out-Null
        (@(Register-OPumper2Filter -Path $catalogue) | ForEach-Object Id) -join ',' | Should -BeExactly 'p.one'
        (@(Register-OPumper2Filter -Path $catalogue) | ForEach-Object Id) -join ',' | Should -BeExactly 'p.one'
        (Resolve-OPumper2Command ptool two).Id | Should -BeExactly 'held'
        $raised = @(Register-OPumper2Filter -Path $catalogue -Priority 2)
        ($raised | ForEach-Object { "$($_.Id)=$($_.Priority)" }) -join ',' | Should -BeExactly 'p.one=0,p.one (ptool two)=2'
        (Resolve-OPumper2Command ptool two).Id | Should -BeExactly 'p.one (ptool two)'
    }
    It 'reports a throwing handler and accepts a valid object handler' {
        Register-OPumper2 -Id broken -Route @('broken') -Handler {throw 'fixture'} | Out-Null
        (Pump-Me broken -AsObject).Error.Code | Should -Be 'HandlerFailed'
        Register-OPumper2 -Id diagnostic -Route @('diagnostic') -Handler {Write-Warning 'fixture'} | Out-Null
        (Pump-Me diagnostic -AsObject).Error.Code | Should -Be 'HandlerFailed'
        $finish = { InModuleScope FrenchExDev.OPumper2.PoSh { New-OP2Completion -Data @{Value=42} } }
        Register-OPumper2 -Id valid -Route @('valid') -Handler $finish | Out-Null
        (Pump-Me valid -AsObject).Data.Value | Should -Be 42
    }
    It 'hands a handler the directory resolved against the PowerShell location' {
        Register-OPumper2 -Id where -Route @('where') -Handler { param($call) New-OPumper2Result -Data $call.WorkingDirectory } | Out-Null
        [void][IO.Directory]::CreateDirectory((Join-Path $TestDrive 'nested'))
        Push-Location $TestDrive
        try { (Pump-Me where -WorkingDirectory nested -AsObject).Data | Should -Be (Join-Path $TestDrive 'nested') }
        finally { Pop-Location }
    }
    It 'delivers the projection a handler result provides and keeps its complete Data local' {
        $handler = { param($call) New-OPumper2Result -Data @{Rows=@(1,2,3)} -Projection {param($data,$settings) @{Count=$data.Rows.Count;MaxItems=$settings.MaxItems}} }
        Register-OPumper2 -Id projected -Route @('projected') -Handler $handler | Out-Null
        (Pump-Me projected -AsObject).Data.Rows.Count | Should -Be 3
        $delivered = (Pump-Me projected -AsJson -MaxItems 4 | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
        $delivered.Data.Count | Should -Be 3
        $delivered.Data.MaxItems | Should -Be 4
        $delivered.Data.ContainsKey('Rows') | Should -BeFalse
    }
    It 'records the route of a routed delivery in the measurement history' {
        $handler = { param($call) FrenchExDev.OPumper2.PoSh\Pump-Me $script:OP2TestExecutable -ArgumentList @('-NoProfile','-NonInteractive','-Command','exit 0') -OnRecord {} -AsObject }
        Register-OPumper2 -Id measured.route -Route @('measured') -Handler $handler | Out-Null
        Pump-Me measured -AsJson | Out-Null
        Pump-Me $script:OP2TestExecutable -ArgumentList @('-NoProfile','-NonInteractive','-Command','exit 0') -OnRecord {} -AsJson | Out-Null
        Pump-Me measured -AsJson | Out-Null
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Executable=$script:OP2TestExecutable} {
            $rows = @(Invoke-OP2Sql (Get-OP2Configuration) 'SELECT route, provider, fingerprint FROM deliveries ORDER BY timestamp DESC LIMIT 3;' -Read)
            "$($rows[0].route)|$($rows[0].provider)" | Should -BeExactly 'measured.route|local'
            $rows[0].fingerprint | Should -BeExactly $rows[2].fingerprint
            $rows[0].fingerprint | Should -BeExactly (Get-OP2Fingerprint ((@('measured') + @((Get-Location).Path)) -join "`0") (Get-OP2Configuration))
            $rows[1].route | Should -BeNullOrEmpty
            $rows[1].provider | Should -BeNullOrEmpty
            $rows[1].fingerprint | Should -BeExactly (Get-OP2Fingerprint ((@($Executable,'-NoProfile','-NonInteractive','-Command','exit 0') + @((Get-Location).Path)) -join "`0") (Get-OP2Configuration))
            $rows[2].route | Should -BeExactly 'measured.route'
        }
    }
}
