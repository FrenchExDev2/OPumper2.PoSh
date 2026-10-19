BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Composition and measurements' {
    It 'preserves assigned failures and nested invocation identifiers' {
        $result=Invoke-OPumper2Task -AsObject -ScriptBlock {
            $ignored=@(Invoke-TestChild 'exit 5')
            $nested=Invoke-OPumper2Task -AsObject -ScriptBlock {$null=@(Invoke-TestChild 'exit 0');@{Nested=$true}}
            [pscustomobject]@{Value=42}
        }
        $result.Outcome | Should -Be 'Failed'
        $result.Data.Value | Should -Be 42
        $result.Execution.InvocationIds.Count | Should -Be 2
        $result.Execution.Issues.Count | Should -BeGreaterThan 0
    }
    It 'reports task failures and serialization as a single measured delivery' {
        (Invoke-OPumper2Task -AsObject -ScriptBlock {throw 'task'}).Error.Code | Should -Be 'TaskFailed'
        $text=Invoke-OPumper2Task -AsJson -ScriptBlock {$null=@(Invoke-TestChild '[Console]::Out.Write("hello world")');$null=@(Invoke-TestChild '[Console]::Out.Write("hello world")');@{Answer=42}}
        ($text | ConvertFrom-Json -NoEnumerate)[0].Data.Answer | Should -Be 42
        $gain=Get-OPumper2Gain -AsObject
        $gain.Outcome | Should -Be 'Success'
        $gain.Data.Compared | Should -BeGreaterThan 0
        $gain.Data.SavedBytes | Should -BeLessThan 0
        Get-OPumper2Gain -AsJson | Should -Match 'SavedBytes'
    }
    It 'counts real tokenizer fixtures and isolates storage failure' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            Get-OP2TokenCount 'hello world' 'o200k_base' | Should -Be 2
            Get-OP2TokenCount '' 'o200k_base' | Should -Be 0
            Get-OP2TokenCount 'hello world' 'cl100k_base' | Should -Be 2
            {Get-OP2TokenCount 'hello' 'missing'} | Should -Throw
            Register-OPumper2Tokenizer -Name invalid -Version fixture -Count {-1}
            {Get-OP2TokenCount 'hello' invalid} | Should -Throw
        }
        $directory=Join-Path $TestDrive 'directory.sqlite'
        [void][IO.Directory]::CreateDirectory($directory)
        $prior=Set-TestEnvironment OPUMPER2_DB_PATH $directory
        try {
            $result=@(Invoke-TestChild 'exit 0')[-1]
            $result.Outcome | Should -Be 'Success'
            $result.Measurement.Status | Should -Be 'StorageUnavailable'
            (Get-OPumper2Gain -AsObject).Outcome | Should -Be 'Failed'
        } finally {$null=Set-TestEnvironment OPUMPER2_DB_PATH $prior}
    }
    It 'obfuscates native observations at the delivery boundary only' {
        try {
            Register-OPumper2Obfuscator -Id fixture.email -TextPattern '[\w.+-]+@[\w-]+\.[\w.]+' -Replacement '[EMAIL]' | Out-Null
            $code='[Console]::Out.WriteLine("https://alice:s3cret@example.com/r.git");[Console]::Out.WriteLine("contact bob@example.com")'
            $arguments=@('-NoProfile','-NonInteractive','-Command',$code)
            $collect=@{State=@{Lines=[Collections.Generic.List[string]]::new()};OnStdOut={param($line,$s)$s.Lines.Add($line)};Complete={param($s,$execution) $s.Lines.ToArray()}}
            $text=Pump-Me $script:OP2TestExecutable -ArgumentList $arguments @collect -AsJson
            $text | Should -Not -Match 's3cret|bob@example'
            ($text | ConvertFrom-Json -NoEnumerate)[0].Data -join '|' | Should -Be 'https://[REDACTED]@example.com/r.git|contact [EMAIL]'
            $collect.State=@{Lines=[Collections.Generic.List[string]]::new()}
            $local=@(Pump-Me $script:OP2TestExecutable -ArgumentList $arguments @collect -AsObject)[-1]
            $local.Data -join '|' | Should -Be 'https://alice:s3cret@example.com/r.git|contact bob@example.com'
        } finally {$null=Unregister-OPumper2Obfuscator fixture.email}
    }
    It 'records only the outer delivery even if a nested step serializes locally' {
        $prior=Set-TestEnvironment OPUMPER2_DB_PATH (Join-Path $TestDrive 'one-delivery.sqlite')
        try {
            $text=Invoke-OPumper2Task -AsJson -ScriptBlock {
                $null=Invoke-OPumper2Task -AsJson -ScriptBlock {
                    $null=FrenchExDev.OPumper2.PoSh\Pump-Me $script:OP2TestExecutable -ArgumentList @('-NoProfile','-Command','[Console]::Out.Write("hello world")') -OnRecord {} -AsJson
                }
                @{Answer=42}
            }
            ($text | ConvertFrom-Json -NoEnumerate)[0].Data.Answer | Should -Be 42
            $gain=Get-OPumper2Gain -AsObject
            $gain.Data.Deliveries | Should -Be 1
            $gain.Data.SourceBytes | Should -Be 11
        } finally {$null=Set-TestEnvironment OPUMPER2_DB_PATH $prior}
    }
}
