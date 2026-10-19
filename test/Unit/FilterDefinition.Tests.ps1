BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Filter definitions' {
    It 'compiles expressions, infers counter modes and applies defaults' {
        $definition = New-TestFilter @{ Id = 'x'; Routes = @('tool run'); Counters = @{ Last = 'v=(?<value>\d+)'; Total = 's=(?<sum>\d+)'; Lines = '.' }
            Groups = @{ Kinds = '^(?<key>\w+)' }; Captures = @{ Final = 'done' }; Keep = @('err'); Drop = @('^#'); Environment = @{ A = '1' } }
        "$($definition.Id)|$($definition.Routes -join ',')|$($definition.Dedupe)|$($definition.SuccessExitCodes -join ',')|$($definition.Arguments.Count)" | Should -BeExactly 'x|tool run|True|0|0'
        (@($definition.Counters.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value.Mode)" }) -join ',') | Should -BeExactly 'Last=Last,Lines=Count,Total=Sum'
        $definition.Groups.Kinds | Should -BeOfType [regex]
        $definition.Captures.Final.IsMatch('all done') | Should -BeTrue
        "$($definition.Keep.Count)|$($definition.Drop.Count)|$($definition.Environment.A)|$($definition.Origin)" | Should -BeExactly '1|1|1|test'
        $bare = New-TestFilter @{ Id = 'y'; Routes = 'tool'; SuccessExitCodes = @(0,1); Dedupe = $false; Arguments = @('--plain') }
        "$($bare.Counters.Count)|$($bare.Groups.Count)|$($bare.Captures.Count)|$($bare.Environment.Count)|$($bare.SuccessExitCodes -join ',')|$($bare.Dedupe)|$($bare.Arguments -join ',')" | Should -BeExactly '0|0|0|0|0,1|False|--plain'
    }
    It 'reads counters, groups and captures named like dictionary members' {
        $definition = New-TestFilter @{ Id = 'keys'; Routes = @('tool'); Counters = @{ Keys = '^k'; Count = '^c' }; Groups = @{ Values = '^v (?<key>\w+)' }; Captures = @{ Keys = '^k (?<text>.+)' } }
        "$(@($definition.Counters.get_Keys()) -join ',')|$(@($definition.Groups.get_Keys()) -join ',')|$(@($definition.Captures.get_Keys()) -join ',')" | Should -BeExactly 'Count,Keys|Values|Keys'
        $definition.Counters['Keys'].Mode | Should -Be 'Count'
    }
    It 'rejects malformed catalogue entries with their origin' {
        foreach ($case in @(
            @(@{ Id = 'a'; Routes = @('t'); Unknown = 1 }, "*test (a): unknown key 'Unknown'*"),
            @(@{ Routes = @('t') }, '*test: a filter needs an Id*'),
            @(@{ Id = 'a' }, '*test (a): a filter needs Routes*'),
            @(@{ Id = 'a'; Routes = @('t'); Keep = @('(') }, "*test (a): invalid expression '('*"),
            @(@{ Id = 'a'; Routes = @('t'); Groups = @{ Kept = '(?<key>x)' } }, "*'Kept' is a reserved group name*"),
            @(@{ Id = 'a'; Routes = @('t'); Groups = @{ Files = 'x' } }, "*group 'Files' needs a (?<key>...) capture*"))) {
            { New-TestFilter $case[0] } | Should -Throw $case[1]
        }
    }
    It 'loads a catalogue folder in file order, selects filters and refuses duplicates or unknown ones' {
        $catalogue = Join-Path $TestDrive 'catalogue'
        [void][IO.Directory]::CreateDirectory($catalogue)
        [IO.File]::WriteAllText((Join-Path $catalogue 'b.psd1'), "@{ Filters = @(@{ Id = 'tool.log'; Routes = @('tool log') }) }")
        [IO.File]::WriteAllText((Join-Path $catalogue 'a.psd1'), "@{ Filters = @(@{ Id = 'tool.run'; Routes = @('tool run', 'tool exec') }, @{ Id = 'tool.test'; Routes = @('tool test') }) }")
        [IO.File]::WriteAllText((Join-Path $catalogue 'notes.txt'), 'not a catalogue')
        (@(Get-OPumper2Filter -Path $catalogue) | ForEach-Object { "$($_.Id)@$($_.Origin)" }) -join ',' | Should -BeExactly 'tool.run@a.psd1,tool.test@a.psd1,tool.log@b.psd1'
        (@(Get-OPumper2Filter -Path $catalogue -Id 'tool.log','tool.run') | ForEach-Object Id) -join ',' | Should -BeExactly 'tool.run,tool.log'
        { Get-OPumper2Filter -Path $catalogue -Id 'tool.log','missing' } | Should -Throw '*Unknown filter: missing.*'
        foreach ($name in @('Get-OPumper2Filter','Register-OPumper2Filter')) {
            ((Get-Command $name).Parameters.Path.Attributes | Where-Object { $_ -is [Management.Automation.ParameterAttribute] }).Mandatory | Should -BeTrue
        }
        $folder = Join-Path $TestDrive 'duplicates'
        [void][IO.Directory]::CreateDirectory($folder)
        foreach ($name in @('a','b')) { [IO.File]::WriteAllText((Join-Path $folder "$name.psd1"), "@{ Filters = @(@{ Id = 'same'; Routes = @('$name') }) }") }
        { Get-OPumper2Filter -Path $folder } | Should -Throw '*Duplicate filter: same.*'
        $empty = Join-Path $TestDrive 'empty'
        [void][IO.Directory]::CreateDirectory($empty)
        @(Get-OPumper2Filter -Path $empty).Count | Should -Be 0
    }
}
