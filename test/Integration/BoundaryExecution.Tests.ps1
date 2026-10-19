BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Presentation and observable failure boundaries' {
    It 'executes with configured limits when the caller runs under WhatIf' {
        # A script invoked with -WhatIf exposes this preference to module code; only the engine calls run under it.
        $prior=$global:WhatIfPreference
        try {
            $global:WhatIfPreference=$true
            $direct=@(FrenchExDev.OPumper2.PoSh\Pump-Me $script:OP2TestExecutable -ArgumentList @('-NoProfile','-Command','[Console]::Out.Write("ready")') -OnRecord {} -AsObject)[-1]
            $routed=FrenchExDev.OPumper2.PoSh\Pump-Me not-an-executable anything -AsObject
        } finally {$global:WhatIfPreference=$prior}
        $direct.Outcome | Should -Be 'Success'
        $direct.Execution.StdoutBytes | Should -Be 5
        $routed.Outcome | Should -Be 'Unsupported'
        (Get-Module FrenchExDev.OPumper2.PoSh).ExportedFunctions.ContainsKey('pump') | Should -BeTrue
        (Get-Module FrenchExDev.OPumper2.PoSh).ExportedAliases.Count | Should -Be 0
    }
    It 'serializes direct calls and preserves zero or many finalizer values' {
        $json=FrenchExDev.OPumper2.PoSh\Pump-Me $script:OP2TestExecutable -ArgumentList @('-NoProfile','-Command','exit 0') -OnRecord {} -Complete {42} -AsJson
        ($json | ConvertFrom-Json -NoEnumerate)[0].Data | Should -Be 42
        $yaml=FrenchExDev.OPumper2.PoSh\Pump-Me $script:OP2TestExecutable -ArgumentList @('-NoProfile','-Command','exit 0') -OnRecord {} -AsYaml
        $yaml | Should -Match 'Completion'
        (@(Invoke-TestChild 'exit 0' @{Complete={}})[-1]).Data | Should -BeNullOrEmpty
        (@(Invoke-TestChild 'exit 0' @{Complete={1;2}})[-1]).Data | Should -Be @(1,2)
        (@(Invoke-TestChild 'exit 0' @{Complete={Write-Warning 'fixture'}})[-1]).Error.Code | Should -Be 'FinalizerFailed'
        $task=Invoke-OPumper2Task -AsObject -ScriptBlock {1;2}
        $task.Data | Should -Be @(1,2)
        (Invoke-OPumper2Task -AsObject -ScriptBlock {Write-Warning 'fixture'}).Error.Code | Should -Be 'TaskFailed'
    }
    It 'kills the owned process after invalid source encoding' {
        $result=@(Invoke-TestChild '[Console]::OpenStandardOutput().WriteByte(255);Start-Sleep -Seconds 10')[-1]
        $result.Outcome | Should -Be 'Failed'
        $result.Error.Code | Should -Be 'ExecutionFailed'
        $result.Execution.ElapsedMs | Should -BeLessThan 5000
        $result.Completeness.Analysis | Should -BeFalse
    }
    It 'continues the business observation if capture creation or writing fails' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Executable=$script:OP2TestExecutable} {
            Mock Open-OP2Capture {throw 'capture fixture'}
            $result=@(Pump-Me $Executable -ArgumentList @('-NoProfile','-Command','[Console]::Out.Write("hello")') -OnRecord {} -AsObject)[-1]
            $result.Outcome | Should -Be 'Success'
            $result.Measurement.Status | Should -Be 'CaptureUnavailable'
            $result.Measurement.SourceBytes | Should -Be 5
            $empty=@(Pump-Me $Executable -ArgumentList @('-NoProfile','-Command','exit 0') -OnRecord {} -AsObject)[-1]
            $empty.Outcome | Should -Be 'Success'
            $empty.Measurement.Status | Should -Be 'CaptureUnavailable'
            $both=@(Pump-Me $Executable -ArgumentList @('-NoProfile','-Command','[Console]::Out.Write("hello");[Console]::Error.Write("err")') -OnRecord {} -AsObject)[-1]
            $both.Measurement.SourceBytes | Should -Be 8
            $failed=@(Pump-Me $Executable -ArgumentList @('-NoProfile','-Command','[Console]::Out.Write("hello");exit 3') -OnRecord {} -AsObject)[-1]
            $failed.Error.Code | Should -Be 'NativeFailed'
            $null -eq $failed.Capture.Stdout | Should -BeTrue
            $failed.Capture.Complete | Should -BeFalse
        }
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Executable=$script:OP2TestExecutable} {
            Mock Open-OP2Capture {$stream=[IO.MemoryStream]::new();$stream.Dispose();$stream}
            $result=@(Pump-Me $Executable -ArgumentList @('-NoProfile','-Command','[Console]::Out.Write("hello")') -OnRecord {} -AsObject)[-1]
            $result.Outcome | Should -Be 'Success'
            $result.Measurement.Status | Should -Be 'CaptureUnavailable'
            $partial=@(Pump-Me $Executable -ArgumentList @('-NoProfile','-Command','[Console]::Out.Write("hello");exit 3') -OnRecord {} -AsObject)[-1]
            $partial.Capture.Stdout | Should -BeExactly ''
            $partial.Capture.Complete | Should -BeFalse
        }
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            $vanished=[FrenchExDev.OPumper2.Engine.NativeCapture]::new('stderr',(Join-Path $Directory 'vanished.capture'),$true,$true,0)
            $capture=Read-OP2Capture @($vanished) 'utf-8' $true
            $capture.Complete | Should -BeFalse
            $null -eq $capture.Stderr | Should -BeTrue
        }
    }
    It 'stores byte measurements when token counts are unknown and reports SQL nulls' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive;Executable=$script:OP2TestExecutable} {
            $config=Get-OP2Configuration
            $empty=Get-OPumper2Gain -AsObject
            $empty.Outcome | Should -Be 'Success'
            Register-OPumper2Tokenizer -Name broken -Version fixture -Count {throw 'counter fixture'}
            $config.Tokenizer='broken'
            $result=New-OP2Completion -Execution @{ExitCode=0;InvocationIds=@([guid]::NewGuid().ToString('N'));ElapsedMs=0;StdoutBytes=0;StderrBytes=0}
            $path=Join-Path $Directory 'counter-source.txt';[IO.File]::WriteAllText($path,'hello')
            $result.Capture=@{Stdout=[IO.File]::ReadAllText($path);Stderr=$null;Complete=$true;Lossy=$false}; Save-OP2Invocation $result $Directory fixture $config
            $result.Measurement.Status | Should -Be 'CounterUnavailable'
            Save-OP2Delivery $result '[{}]' $config
            $result.Measurement.Status | Should -Be 'DeliveredWithoutTokens'
            $nullRow=@(Invoke-OP2Sql -Configuration $config -Read -Sql 'SELECT @value AS Value' -Parameters @{value=$null})[0]
            $nullRow.Value | Should -BeNullOrEmpty
            $config.DatabasePath=Join-Path $Directory 'unwritable-directory'
            [void][IO.Directory]::CreateDirectory($config.DatabasePath)
            Save-OP2Delivery $result '[]' $config
            $result.Measurement.Status | Should -Be 'DeliveryUnavailable'
        }
    }
    It 'reports empty history and zero denominators without inventing token savings' {
        $prior=Set-TestEnvironment OPUMPER2_DB_PATH (Join-Path $TestDrive 'empty-history.sqlite')
        try {
            $empty=Get-OPumper2Gain -AsObject
            $empty.Data.Deliveries | Should -Be 0
            $empty.Data.SavedTokens | Should -BeNullOrEmpty
            $empty.Data.Rate | Should -BeNullOrEmpty
            # Gain data is a domain value: its zeros are delivered, only the envelope is compacted.
            $delivered=(Get-OPumper2Gain -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
            $delivered.Data.Deliveries | Should -Be 0
            $delivered.Data.ContainsKey('SavedBytes') | Should -BeTrue
            $delivered.ContainsKey('Truncation') | Should -BeFalse
        } finally {$null=Set-TestEnvironment OPUMPER2_DB_PATH $prior}
    }
}
