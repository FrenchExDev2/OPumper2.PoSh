BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    # Framing itself is the engine assembly's (engine/FrenchExDev.OPumper2.Engine.Tests); these tests cover dispatch.
    function New-TestRecord([string]$Stream, [string]$Text, [long]$Sequence) { [FrenchExDev.OPumper2.Engine.Record]::new($Stream, $Text, $Sequence) }
}

Describe 'Record dispatch and child configuration' {
    It 'hands the record callback each record, else the matching stream callback its text' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Records=@((New-TestRecord 'stdout' 'a' 1), (New-TestRecord 'stderr' 'b' 2))} {
            $state=[Collections.Generic.List[string]]::new()
            $streams=New-OP2CallbackContext @{OnRecord=$null;OnStdOut={param($text,$s)$s.Add('out:'+$text)};OnStdErr={param($text,$s)$s.Add('err:'+$text)};State=$state;MaxRecordCharacters=4}
            Invoke-OP2Dispatch $Records $streams
            $state.ToArray() | Should -Be @('out:a','err:b')
            $seen=[Collections.Generic.List[object]]::new()
            $record=New-OP2CallbackContext @{OnRecord={param($r,$s)$s.Add($r)};OnStdOut={throw 'unused'};OnStdErr=$null;State=$seen;MaxRecordCharacters=4}
            Invoke-OP2Dispatch $Records $record
            (@($seen | ForEach-Object { "$($_.Stream):$($_.Text):$($_.Sequence):$($_.Truncated)" }) -join '|') | Should -BeExactly 'stdout:a:1:False|stderr:b:2:False'
            $record.Failure | Should -BeNullOrEmpty
        }
    }
    It 'streams callback values in record order without enumerating them' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Records=@((New-TestRecord 'stdout' 'x' 1), (New-TestRecord 'stdout' 'y' 2))} {
            $context=New-OP2CallbackContext @{OnRecord={param($r,$s),@($r.Text,'second')};OnStdOut=$null;OnStdErr=$null;State=@{};MaxRecordCharacters=4}
            $values=@(Invoke-OP2Dispatch $Records $context)
            $values.Count | Should -Be 2
            ($values | ForEach-Object { $_ -join '+' }) -join '|' | Should -BeExactly 'x+second|y+second'
        }
    }
    It 'retains the first callback failure, then stops dispatching, and refuses diagnostic records' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Records=@((New-TestRecord 'stderr' 'a' 1), (New-TestRecord 'stderr' 'b' 2))} {
            $calls=@{Count=0}
            $context=New-OP2CallbackContext @{OnRecord={param($r,$s)$s.Count++;Write-Information 'fixture' -InformationAction Continue};OnStdOut=$null;OnStdErr=$null;State=$calls;MaxRecordCharacters=4}
            @(Invoke-OP2Dispatch $Records $context).Count | Should -Be 0
            $context.Failure.Code | Should -Be 'CallbackFailed'
            $calls.Count | Should -Be 1
            Invoke-OP2Dispatch $Records $context
            $calls.Count | Should -Be 1
        }
    }
    It 'hands the batch callback each non-empty batch whole, in one call, and stops after its first failure' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Records=@((New-TestRecord 'stdout' 'a' 1), (New-TestRecord 'stderr' 'b' 2))} {
            $seen=[Collections.Generic.List[string]]::new()
            $context=New-OP2CallbackContext @{OnRecord={throw 'unused'};OnBatch={param($batch,$s)$s.Add((@($batch | ForEach-Object { "$($_.Stream):$($_.Text)" }) -join ',')); ,@($batch.Count,'values')};OnStdOut=$null;OnStdErr=$null;State=$seen;MaxRecordCharacters=4}
            $values=@(Invoke-OP2Dispatch $Records $context)
            Invoke-OP2Dispatch @() $context
            ($values | ForEach-Object { $_ -join '+' }) -join '|' | Should -BeExactly '2+values'
            ($seen -join '|') | Should -BeExactly 'stdout:a,stderr:b'
            $context.Failure | Should -BeNullOrEmpty
            # A diagnostic stream fails the batch callback like any callback; later batches are not handed over.
            $calls=@{Count=0}
            $failing=New-OP2CallbackContext @{OnRecord=$null;OnBatch={param($batch,$s)$s.Count++;Write-Warning 'fixture'};OnStdOut=$null;OnStdErr=$null;State=$calls;MaxRecordCharacters=4}
            @(Invoke-OP2Dispatch $Records $failing).Count | Should -Be 0
            Invoke-OP2Dispatch $Records $failing
            "$($failing.Failure.Code)|$($calls.Count)" | Should -BeExactly 'CallbackFailed|1'
            # A call shape without the key, such as an older replay, has no batch callback.
            (New-OP2CallbackContext @{OnRecord={};OnStdOut=$null;OnStdErr=$null;State=$null;MaxRecordCharacters=4}).OnBatch | Should -BeNullOrEmpty
        }
    }
    It 'dispatches nothing without a callback for the stream' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Records=@((New-TestRecord 'stdout' 'a' 1), (New-TestRecord 'stderr' 'b' 2))} {
            $state=[Collections.Generic.List[string]]::new()
            $context=New-OP2CallbackContext @{OnRecord=$null;OnStdOut=$null;OnStdErr={param($text,$s)$s.Add($text)};State=$state;MaxRecordCharacters=4}
            @(Invoke-OP2Dispatch $Records $context).Count | Should -Be 0
            $state.ToArray() | Should -Be @('b')
            $context.Failure | Should -BeNullOrEmpty
        }
    }
    It 'builds a hidden redirected child configuration without starting it' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            $info=New-OP2StartInfo @{Command='fixture';ArgumentList=@('a b','--flag');InputText='';WorkingDirectory=$Directory;Environment=@{OP2_CHILD_CONFIG='value'};Encoding='utf-8'}
            $info.CreateNoWindow | Should -BeTrue
            $info.UseShellExecute | Should -BeFalse
            $info.RedirectStandardOutput | Should -BeTrue
            $info.RedirectStandardError | Should -BeTrue
            $info.RedirectStandardInput | Should -BeTrue
            "$($info.StandardInputEncoding.CodePage)|$($info.StandardInputEncoding.GetPreamble().Length)" | Should -BeExactly '65001|0'
            (New-OP2StartInfo @{Command='fixture';ArgumentList=@();InputText=$null;WorkingDirectory=$Directory;Environment=@{};Encoding='utf-8'}).StandardInputEncoding | Should -BeNullOrEmpty
            (Get-OP2InputEncoding 'utf-16').CodePage | Should -Be 1200
            $info.ArgumentList | Should -Be @('a b','--flag')
            $info.Environment['OP2_CHILD_CONFIG'] | Should -Be 'value'
        }
    }
}
