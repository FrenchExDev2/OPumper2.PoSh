BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'pump command line' {
    It 'takes Pump-Me options before the command and passes every later argument verbatim' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            # A simple function receives the same $args entries as pump.
            function Split-TestLine { ,$args }
            $block={param($record,$state)}
            $call=ConvertFrom-OP2CommandLine (Split-TestLine -OnRecord $block -AsObject -TimeoutSeconds:5 -AsJson:$false dotnet build -c Release -o out -v q -p:Configuration=Release) ''
            $call.Command | Should -Be 'dotnet'
            $call.ArgumentList | Should -Be @('build','-c','Release','-o','out','-v','q','-p:Configuration=Release')
            [object]::ReferenceEquals($call.OnRecord,$block) | Should -BeTrue
            $call.AsObject | Should -BeTrue
            $call.TimeoutSeconds | Should -Be 5
            $call.AsJson | Should -BeFalse
            (@($call.Keys | Sort-Object) -join ',') | Should -Be 'ArgumentList,AsJson,AsObject,Command,OnRecord,TimeoutSeconds'
            $files=@('a.txt','b.txt')
            $values=ConvertFrom-OP2CommandLine (Split-TestLine git add $files 5 1.5 $true $null '-c' '-p:' x -AsObject) ''
            $values.ArgumentList | Should -Be @('add','a.txt','b.txt','5','1.5','True','-c','-p:','x','-AsObject')
            $values.ContainsKey('AsObject') | Should -BeFalse
            (ConvertFrom-OP2CommandLine (Split-TestLine '-literal' x) '').Command | Should -Be '-literal'
            (ConvertFrom-OP2CommandLine (Split-TestLine git) '').ArgumentList.Count | Should -Be 0
            # A colon token with nothing after it stays as written.
            $token=[psobject]'-x:'
            $token.PSObject.Properties.Add([psnoteproperty]::new('<CommandParameterName>','x'))
            (ConvertFrom-OP2CommandLine @('tool',$token) '').ArgumentList | Should -Be @('-x:')
        }
    }
    It 'rejects unknown or incomplete options and options after the command' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            function Split-TestLine { ,$args }
            { ConvertFrom-OP2CommandLine (Split-TestLine -Unknown git) '' } | Should -Throw "*Unknown pump option '-Unknown'*"
            { ConvertFrom-OP2CommandLine (Split-TestLine -Verbose git) '' } | Should -Throw '*Unknown pump option*'
            { ConvertFrom-OP2CommandLine (Split-TestLine -ArgumentList x git) '' } | Should -Throw '*Unknown pump option*'
            { ConvertFrom-OP2CommandLine (Split-TestLine -AsO git) '' } | Should -Throw '*Unknown pump option*'
            { ConvertFrom-OP2CommandLine (Split-TestLine -AsObject) '' } | Should -Throw '*Missing command*'
            { ConvertFrom-OP2CommandLine @() '' } | Should -Throw '*Missing command*'
            { ConvertFrom-OP2CommandLine (Split-TestLine -TimeoutSeconds) '' } | Should -Throw "*Missing value for pump option '-TimeoutSeconds'*"
            { ConvertFrom-OP2CommandLine (Split-TestLine git status -OnRecord {}) '' } | Should -Throw '*precede the command*'
            { ConvertFrom-OP2CommandLine (Split-TestLine git -Environment @{A=1}) '' } | Should -Throw '*precede the command*'
        }
    }
    It 'refuses a -- that PowerShell removed after the command' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $options=Get-OP2PumpOption
            $options.AsObject | Should -BeTrue
            $options.TimeoutSeconds | Should -BeFalse
            foreach($statement in @(
                'pump git checkout -- main',
                'pump -AsObject git -- x',
                'pump -TimeoutSeconds:5 git -- x',
                'pump -OnRecord {} git -- x',
                '$result = FrenchExDev.OPumper2.PoSh\pump git diff -- a'
            )) { { Assert-OP2Separator $statement $options } | Should -Throw "*removed the first '--'*" }
            foreach($statement in @(
                'pump -- git checkout -- main',
                'pump -AsObject -- git checkout -- main',
                'pump -Encoding utf-8 -- git diff -- a',
                'pump @options -- git diff -- a',
                'pump -AsObject',
                'pump git status',
                'pump -OnRecord { pump nested -- x } git status',
                'other git -- x',
                ''
            )) { { Assert-OP2Separator $statement $options } | Should -Not -Throw }
        }
    }
}
