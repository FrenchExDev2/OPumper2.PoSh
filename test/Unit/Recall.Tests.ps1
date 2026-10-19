BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    function New-RecallConfiguration([string]$Name) {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Path = (Join-Path $TestDrive "$Name.sqlite") } { $c = Get-OP2Configuration; $c.DatabasePath = $Path; $c }
    }
    function New-RecalledCompletion([string]$Outcome = 'Failed', [string]$Stdout = "one`ntwo token=abc`nthree", [string]$Stderr = 'fatal', [string]$Invocation = ([guid]::NewGuid().ToString('N'))) {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Outcome = $Outcome; Stdout = $Stdout; Stderr = $Stderr; Invocation = $Invocation } {
            $c = New-OP2Completion -Outcome $Outcome -Execution @{ ExitCode = 3; InvocationIds = @($Invocation); ElapsedMs = 1; StdoutBytes = 20; StderrBytes = 5 }
            $c.Capture = @{ Stdout = $Stdout; Stderr = $Stderr; Complete = $true; Lossy = $false }
            $c
        }
    }
}

Describe 'Recall store' {
    It 'compresses outputs losslessly and keeps a missing stream missing' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $text = "é`nline`r`n" + ('x' * 5000)
            ConvertFrom-OP2RecallBlob (ConvertTo-OP2RecallBlob $text) | Should -BeExactly $text
            (ConvertTo-OP2RecallBlob $text).Length | Should -BeLessThan 200
            ConvertTo-OP2RecallBlob $null | Should -BeNullOrEmpty
            ConvertFrom-OP2RecallBlob $null | Should -BeNullOrEmpty
        }
    }
    It 'keeps delivered native outputs according to the tracking and recall settings' {
        $failed = New-RecalledCompletion
        $success = New-RecalledCompletion -Outcome Success
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Failed = $failed; Success = $success } {
            $config = Get-OP2Configuration
            Test-OP2RecallWanted $Success $config | Should -BeTrue
            $config.Recall = 'failures'
            Test-OP2RecallWanted $Success $config | Should -BeFalse
            Test-OP2RecallWanted $Failed $config | Should -BeTrue
            $config.Recall = 'off'
            Test-OP2RecallWanted $Failed $config | Should -BeFalse
            $config.Recall = 'on'; $config.Tracking = $false
            Test-OP2RecallWanted $Failed $config | Should -BeFalse
            $config.Tracking = $true
            Test-OP2RecallWanted (New-OP2Completion -Outcome Failed) $config | Should -BeFalse
            $orphan = New-OP2Completion -Outcome Failed; $orphan.Capture = @{ Stdout = 'x'; Stderr = $null; Complete = $true; Lossy = $false }
            Test-OP2RecallWanted $orphan $config | Should -BeFalse
            Test-OP2RecallWanted ([pscustomobject]@{ Outcome = 'Failed'; Execution = @{ InvocationIds = @('x') } }) $config | Should -BeFalse
        }
    }
    It 'stores a masked, compressed output under the prefix of its invocation and reads it back' {
        $config = New-RecallConfiguration 'store'
        $completion = New-RecalledCompletion -Invocation 'abcdef0123456789abcdef0123456789'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Config = $config; Completion = $completion; Directory = $TestDrive } {
            $id = Save-OP2Recall $Completion $Config @{ Label = 'tool'; Route = 'tool.route'; WorkingDirectory = $Directory }
            $id | Should -BeExactly 'abcdef012345'
            $recall = Read-OP2Recall $id $Config
            $recall.Stdout | Should -BeExactly "one`ntwo token=[REDACTED]`nthree"
            $recall.Stderr | Should -BeExactly 'fatal'
            "$($recall.Label)|$($recall.Route)|$($recall.Outcome)|$($recall.ExitCode)|$($recall.Complete)|$($recall.Masked)" | Should -BeExactly 'tool|tool.route|Failed|3|True|True'
            $row = @(Invoke-OP2Sql $Config 'SELECT project, invocation, stdout_bytes, stderr_bytes FROM recalls;' -Read)[0]
            "$($row.project)|$($row.invocation)|$($row.stdout_bytes)|$($row.stderr_bytes)" | Should -BeExactly "$(Get-OP2ProjectHash $Directory)|abcdef0123456789abcdef0123456789|20|5"
            { Read-OP2Recall 'missing' $Config } | Should -Throw '*Unknown recall: missing.*'
            $Config.RecallMask = $false
            $raw = New-OP2Completion -Outcome Failed -Execution @{ ExitCode = 1; InvocationIds = @('11112222333344445555666677778888') }
            $raw.Capture = @{ Stdout = 'token=abc'; Stderr = $null; Complete = $false; Lossy = $false }
            $rawId = Save-OP2Recall $raw $Config
            (Read-OP2Recall $rawId $Config).Stdout | Should -BeExactly 'token=abc'
            (Read-OP2Recall $rawId $Config).Stderr | Should -BeNullOrEmpty
            (Read-OP2Recall $rawId $Config).Complete | Should -BeFalse
            @(Invoke-OP2Sql $Config 'SELECT project FROM recalls WHERE id=@id;' @{ id = $rawId } -Read)[0].project | Should -BeExactly (Get-OP2ProjectHash (Get-Location).Path)
        }
    }
    It 'keeps the end of an oversized output, the most recent entries and the retention window' {
        $config = New-RecallConfiguration 'limits'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Config = $config } {
            $Config.RecallMaxEntryBytes = 5
            $long = New-OP2Completion -Outcome Failed -Execution @{ ExitCode = 1; InvocationIds = @('aaaaaaaaaaaa0000000000000000000a') }
            $long.Capture = @{ Stdout = '0123456789'; Stderr = 'abc'; Complete = $true; Lossy = $false }
            $id = Save-OP2Recall $long $Config
            $recall = Read-OP2Recall $id $Config
            "$($recall.Stdout)|$($recall.Stderr)|$($recall.Complete)" | Should -BeExactly '56789|abc|False'
            $Config.RecallMaxEntryBytes = 1000; $Config.RecallMaxEntries = 2
            foreach ($prefix in @('b','c','d')) {
                $entry = New-OP2Completion -Outcome Failed -Execution @{ ExitCode = 1; InvocationIds = @(($prefix * 12) + ('0' * 20)) }
                $entry.Capture = @{ Stdout = $prefix; Stderr = $null; Complete = $true; Lossy = $false }
                Save-OP2Recall $entry $Config | Out-Null
                [Threading.Thread]::Sleep(5)
            }
            (@(Invoke-OP2Sql $Config 'SELECT id FROM recalls ORDER BY id;' -Read) | ForEach-Object id) -join ',' | Should -BeExactly 'cccccccccccc,dddddddddddd'
            Invoke-OP2Sql $Config "UPDATE recalls SET timestamp='2020-01-01T00:00:00.0000000Z' WHERE id='cccccccccccc'; INSERT INTO recall_reads VALUES('r','cccccccccccc','2020-01-01T00:00:00Z','lines',1,1);"
            $Config.RecallMaxEntries = 0; $Config.RecallRetentionDays = 0
            $keep = New-OP2Completion -Outcome Failed -Execution @{ ExitCode = 1; InvocationIds = @(('e' * 12) + ('0' * 20)) }; $keep.Capture = @{ Stdout = 'e'; Stderr = $null; Complete = $true; Lossy = $false }
            Save-OP2Recall $keep $Config | Out-Null
            @(Invoke-OP2Sql $Config 'SELECT COUNT(*) AS Count FROM recalls;' -Read)[0].Count | Should -Be 3
            $Config.RecallRetentionDays = 30
            $last = New-OP2Completion -Outcome Failed -Execution @{ ExitCode = 1; InvocationIds = @(('f' * 12) + ('0' * 20)) }; $last.Capture = @{ Stdout = 'f'; Stderr = $null; Complete = $true; Lossy = $false }
            Save-OP2Recall $last $Config | Out-Null
            (@(Invoke-OP2Sql $Config 'SELECT id FROM recalls ORDER BY id;' -Read) | ForEach-Object id) -join ',' | Should -BeExactly 'dddddddddddd,eeeeeeeeeeee,ffffffffffff'
            @(Invoke-OP2Sql $Config 'SELECT COUNT(*) AS Count FROM recall_reads;' -Read)[0].Count | Should -Be 0
            $Config.DatabasePath = Join-Path (Split-Path $Config.DatabasePath) 'missing-folder-file'
            [void][IO.Directory]::CreateDirectory($Config.DatabasePath)
            Save-OP2Recall $last $Config | Should -BeNullOrEmpty
        }
    }
    It 'replays a recalled output through a contract as the native runner frames it' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $recall = [pscustomobject]@{ Id = 'r'; Stdout = "a`r`nb`nc"; Stderr = 'e'; ExitCode = 4; Complete = $true }
            $state = [Collections.Generic.List[string]]::new()
            $done = Invoke-OP2Replay $recall (New-OP2ReplayCall -OnRecord { param($r,$s) $s.Add("$($r.Stream):$($r.Text)") } -State $state -Complete { param($s,$e) "$($s.Count)/$($e.Recall)/$($e.ExitCode)" })
            ($state -join '|') | Should -BeExactly 'stdout:a|stdout:b|stdout:c|stderr:e'
            $done.Outcome | Should -Be 'Success'
            $done.Data | Should -BeExactly '4/r/4'
            # One finalizer value is the Data itself; several form a list.
            $done.Data -is [string] | Should -BeTrue
            $pair = Invoke-OP2Replay $recall (New-OP2ReplayCall -OnRecord {} -Complete { 'a'; 'b' })
            "$($pair.Data.Count)|$($pair.Data -join ',')" | Should -BeExactly '2|a,b'
            "$($done.Execution.Records)|$($done.Completeness.Source)|$($done.Completeness.Analysis)" | Should -BeExactly '4|True|True'
            $streams = @{ Out = 0; Err = 0 }
            Invoke-OP2Replay $recall (New-OP2ReplayCall -OnStdOut { param($l,$s) $s.Out++ } -OnStdErr { param($l,$s) $s.Err++ } -State $streams) | Out-Null
            "$($streams.Out)/$($streams.Err)" | Should -BeExactly '3/1'
            # A batch callback receives each stream of the recall as one batch, stdout first.
            $batches = [Collections.Generic.List[string]]::new()
            Invoke-OP2Replay $recall (New-OP2ReplayCall -OnBatch { param($records,$s) $s.Add((@($records | ForEach-Object Text) -join ',')) } -State $batches) | Out-Null
            ($batches -join '|') | Should -BeExactly 'a,b,c|e'
            $failed = Invoke-OP2Replay $recall (New-OP2ReplayCall -OnRecord { throw 'fixture' })
            "$($failed.Outcome)|$($failed.Error.Code)" | Should -BeExactly 'Failed|CallbackFailed'
            $limited = Invoke-OP2Replay $recall (New-OP2ReplayCall -OnRecord {} -MaxRecordCharacters 2)
            $limited.Outcome | Should -Be 'Success'
            $limited.Error | Should -BeNullOrEmpty
            $long = [pscustomobject]@{ Id = 'l'; Stdout = 'abc'; Stderr = $null; ExitCode = 0; Complete = $false }
            $lost = Invoke-OP2Replay $long (New-OP2ReplayCall -OnRecord {} -MaxRecordCharacters 2)
            "$($lost.Outcome)|$($lost.Error.Code)|$($lost.Completeness.Source)" | Should -BeExactly 'Failed|RecordLimit|False'
        }
    }
    It 'reads lines of a recalled output, records each read and lists the store' {
        $config = New-RecallConfiguration 'reads'
        $stdout = (1..30 | ForEach-Object { "line $_" }) -join "`n"
        $completion = New-RecalledCompletion -Stdout $stdout -Stderr "err one`nerr two" -Invocation '0123456789ab0000000000000000000a'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Config = $config; Completion = $completion } { Save-OP2Recall $Completion $Config @{ Label = 'tool' } | Out-Null }
        $database = $config.DatabasePath
        $grep = (Get-OPumper2Recall '0123456789ab' -Grep 'line 1\d$' -Lines 2 -DatabasePath $database -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
        "$($grep.Data.Lines)|$($grep.Data.Matched)|$($grep.Data.Command)|$($grep.Data.Outcome)" | Should -BeExactly '32|10|tool|Failed'
        ($grep.Data.Text -join ',') | Should -BeExactly '10: line 10,11: line 11'
        $grep.Recall | Should -BeNullOrEmpty
        $from = (Get-OPumper2Recall '0123456789ab' -From 29 -DatabasePath $database -MaxItems 1 -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
        ($from.Data.Text -join ',') | Should -BeExactly '29: line 29'
        $from.Data.Omitted.Text | Should -Be 3
        $errors = Get-OPumper2Recall '0123456789ab' -Stream stderr -DatabasePath $database -AsObject
        ($errors.Data.Text -join ',') | Should -BeExactly '1: err one,2: err two'
        $out = Get-OPumper2Recall '0123456789ab' -Stream stdout -DatabasePath $database -AsObject
        $out.Data.Lines | Should -Be 30
        $yaml = Get-OPumper2Recall '0123456789ab' -Lines 1 -DatabasePath $database -MaxOutputBytes 4096
        $yaml | Should -Match '1: line 1'
        $contract = (Invoke-OPumper2Recall '0123456789ab' -State @{ N = 0 } -OnRecord { param($r,$s) $s.N++ } -Complete { param($s) $s.N } -DatabasePath $database -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
        $contract.Data | Should -Be 32
        $contract.Execution.Recall | Should -BeExactly '0123456789ab'
        (Invoke-OPumper2Recall '0123456789ab' -State @{ N = 0 } -OnBatch { param($records,$s) $s.N += $records.Count } -Complete { param($s) $s.N } -DatabasePath $database -AsObject).Data | Should -Be 32
        Invoke-OPumper2Recall '0123456789ab' -OnStdOut { param($l,$s) $s.N++ } -State @{ N = 0 } -DatabasePath $database -MaxItems 1 -MaxOutputBytes 4096 -ExcerptLines 0 | Should -Match 'Recall: 0123456789ab'
        (Invoke-OPumper2Recall '0123456789ab' -OnRecord {} -DatabasePath $database -AsObject).Execution.Recall | Should -BeExactly '0123456789ab'
        $reads = InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Config = $config } { @(Invoke-OP2Sql $Config 'SELECT mode, bytes, tokens FROM recall_reads ORDER BY timestamp;' -Read) }
        (@($reads | ForEach-Object mode) -join ',') | Should -BeExactly 'lines,lines,lines,contract,contract'
        @($reads | Where-Object { $_.bytes -le 0 -or $_.tokens -le 0 }).Count | Should -Be 0
        $list = (Get-OPumper2Recall -List -DatabasePath $database -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
        "$($list.Data.Recalls[0].Id)|$($list.Data.Recalls[0].Command)|$($list.Data.Recalls[0].Outcome)|$($list.Data.Recalls[0].Bytes)" | Should -BeExactly '0123456789ab|tool|Failed|25'
        (Get-OPumper2Recall -List -DatabasePath $database -AsObject).Data.Recalls.Count | Should -Be 1
        Get-OPumper2Recall -List -DatabasePath $database -MaxItems 0 -MaxOutputBytes 4096 | Should -Match 'Recalls: 1'
        { Get-OPumper2Recall 'missing' -DatabasePath $database } | Should -Throw '*Unknown recall*'
        # The smallest accepted bounds.
        Get-OPumper2Recall '0123456789ab' -From 1 -Lines 1 -DatabasePath $database -MaxOutputBytes 256 | Should -Match 'Kind: Completion'
        Get-OPumper2Recall -List -DatabasePath $database -MaxOutputBytes 256 | Should -Match 'Kind: Completion'
        (Invoke-OPumper2Recall '0123456789ab' -OnRecord {} -DatabasePath $database -MaxItems 0 -MaxOutputBytes 256 -AsJson | ConvertFrom-Json)[0].Kind | Should -BeExactly 'Completion'
    }
    It 'names a routed recall by its route and masks it with a top-level obfuscation context' {
        $config = New-RecallConfiguration 'routed'
        $completion = New-RecalledCompletion -Invocation 'cafe00000000ffff0000000000000000'
        $contexts = [Collections.Generic.List[string]]::new()
        Register-OPumper2Obfuscator -Id fixture.recall.context -Middleware { param($value, $context) $contexts.Add("$($context.Key)/$($context.Path)/$($context.Depth)"); $value }.GetNewClosure() | Out-Null
        try {
            InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Config = $config; Completion = $completion } { Save-OP2Recall $Completion $Config @{ Label = 'tool'; Route = 'tool.route' } | Out-Null }
        } finally { Unregister-OPumper2Obfuscator -Id fixture.recall.context | Out-Null }
        ($contexts -join ',') | Should -BeExactly 'Stdout/Recall.Stdout/0,Stderr/Recall.Stderr/0'
        (Get-OPumper2Recall 'cafe00000000' -DatabasePath $config.DatabasePath -AsObject).Data.Command | Should -BeExactly 'tool.route'
    }
    It 'replays records up to the native record size' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            foreach ($length in @(65536, 65537)) {
                $recall = [pscustomobject]@{ Id = 'w'; Stdout = ('x' * $length); Stderr = $null; ExitCode = 0; Complete = $true }
                $replayed = Invoke-OP2Replay $recall (New-OP2ReplayCall -OnRecord {})
                "$length=$($replayed.Outcome)" | Should -BeExactly $(if ($length -eq 65536) { '65536=Success' } else { '65537=Failed' })
            }
        }
    }
    It 'records no read when tracking is off and reports a read it cannot record' {
        $config = New-RecallConfiguration 'untracked'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Config = $config; Completion = (New-RecalledCompletion -Invocation 'feedfacefeed0000000000000000000a') } {
            Save-OP2Recall $Completion $Config | Out-Null
            $Config.Tracking = $false
            $result = New-OP2Completion -Data 'x'
            Send-OP2RecallRead $result 'feedfacefeed' 'lines' @{ AsJson = $true } $Config | Should -Match '"Data":"x"'
            @(Invoke-OP2Sql $Config 'SELECT COUNT(*) AS Count FROM recall_reads;' -Read)[0].Count | Should -Be 0
            $Config.Tracking = $true; $Config.DatabasePath = Join-Path (Split-Path $Config.DatabasePath) 'read-folder'
            [void][IO.Directory]::CreateDirectory($Config.DatabasePath)
            Send-OP2RecallRead $result 'feedfacefeed' 'lines' @{ AsYaml = $true; MaxItems = 1 } $Config | Should -Match 'Data: x'
            $result.Measurement.Status | Should -Be 'DeliveryUnavailable'
            [object]::ReferenceEquals((Send-OP2RecallRead $result 'x' 'lines' @{ AsObject = $true } $Config), $result) | Should -BeTrue
        }
    }
}
