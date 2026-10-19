BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    function New-TestTimingConfiguration {
        # A configuration with its own database, so each test reads only its own history.
        param([string]$Name)
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Path = (Join-Path $TestDrive "$Name.sqlite") } { $config = Get-OP2Configuration; $config.DatabasePath = $Path; $config }
    }
}

Describe 'Phase durations' {
    It 'converts clock ticks to milliseconds' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $second = [Diagnostics.Stopwatch]::Frequency
            Get-OP2Duration 10 (10 + $second / 4) | Should -Be 250
            (Get-OP2Timestamp) -gt 0 | Should -BeTrue
        }
    }
    It 'stores the phases of an invocation and of its delivery, and the import once per session' {
        $config = New-TestTimingConfiguration 'phases'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Config = $config; Directory = $TestDrive } {
            # One millisecond passes at each reading of the clock.
            $script:TestTick = 0L
            Mock Get-OP2Timestamp { $script:TestTick += [Diagnostics.Stopwatch]::Frequency / 1000; $script:TestTick }
            $timing = [ordered]@{ SetupMs = 1.5; ProcessMs = 120; BackpressureMs = 7; CallbackMs = 3; CompleteMs = 2; CaptureMs = 4 }
            $id = [guid]::NewGuid().ToString('N')
            $result = New-OP2Completion -Execution @{ ExitCode = 0; InvocationIds = @($id); ElapsedMs = 130; StdoutBytes = 5; StderrBytes = 0; Records = 9; Timing = $timing }
            $result.Capture = @{ Stdout = 'hello'; Stderr = $null; Complete = $true; Lossy = $false }
            $scope = Enter-OP2Call 0
            try {
            Save-OP2Invocation $result $Directory fixture $Config
            $row = @(Invoke-OP2Sql $Config 'SELECT setup_ms, process_ms, callback_ms, backpressure_ms, complete_ms, capture_ms, tokens_ms, records FROM invocations WHERE id=@id;' @{ id = $id } -Read)[0]
            "$($row.setup_ms)|$($row.process_ms)|$($row.callback_ms)|$($row.backpressure_ms)|$($row.complete_ms)|$($row.capture_ms)|$($row.tokens_ms)|$($row.records)" | Should -BeExactly '1.5|120|3|7|2|4|1|9'
            # The invocation's write is recorded for its delivery: one clock reading before it, one after.
            "$($scope.Account.StorageWrites.Count)|$($scope.Account.StorageWrites[0].Ms)" | Should -BeExactly '1|1'
            $previous = $script:OP2ImportPending; $importMs = $script:OP2ImportMs
            try {
                $script:OP2ImportPending = $true; $script:OP2ImportMs = 42
                # A write before the entry is not this delivery's; one after it is (1 ms).
                $entered = $script:TestTick
                Add-OP2StorageWrite $entered
                # The delivery counts its tokens (1 ms), then closes its total: 4 ms since the entry.
                Save-OP2Delivery $result '[{}]' $Config -Timing @{ Entered = $entered; RecallMs = 5; FormatMs = 6 }
                Save-OP2Delivery $result '[{}]' $Config -Timing @{}
                $rows = @(Invoke-OP2Sql $Config 'SELECT total_ms, recall_ms, format_ms, tokens_ms, storage_ms, import_ms FROM deliveries ORDER BY total_ms DESC;' -Read)
                ($rows | ForEach-Object { "$($_.total_ms)|$($_.recall_ms)|$($_.format_ms)|$($_.tokens_ms)|$($_.storage_ms)|$($_.import_ms)" }) -join ',' | Should -BeExactly '4|5|6|1|1|42,|||1||'
                $script:OP2ImportPending | Should -BeFalse
            } finally { $script:OP2ImportPending = $previous; $script:OP2ImportMs = $importMs }
            # A completion without timing, a call that did not run natively, stores nulls.
            $plain = New-OP2Completion -Execution @{ ExitCode = 0; InvocationIds = @('plain'); ElapsedMs = 1; StdoutBytes = 0; StderrBytes = 0 }
            $plain.Capture = @{ Stdout = ''; Stderr = $null; Complete = $true; Lossy = $false }
            Save-OP2Invocation $plain $Directory fixture $Config
            $none = @(Invoke-OP2Sql $Config "SELECT setup_ms, records FROM invocations WHERE id='plain';" -Read)[0]
            "$($null -eq $none.setup_ms)|$($null -eq $none.records)" | Should -BeExactly 'True|True'
            } finally { Exit-OP2Call $scope }
        }
    }
    It 'keeps the durations on the local object and out of every delivery' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            Mock Save-OP2Recall {}
            Mock Save-OP2Delivery {}
            $completion = New-OP2Completion -Execution @{ ExitCode = 0; InvocationIds = @(); ElapsedMs = 1; Timing = [ordered]@{ ProcessMs = 5 } }
            foreach ($format in @('json', 'yaml')) { ConvertTo-OPumper2Output @($completion) -Format $format | Should -Not -Match 'Timing|ProcessMs' }
            @(ConvertTo-OPumper2Output @($completion) -Format object)[0].Execution.Timing.ProcessMs | Should -Be 5
        }
    }
    It 'times the delivery from the entry into pump, and its recall and formatting, the recall write apart' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $script:TestTick = 0L
            Mock Get-OP2Timestamp { $script:TestTick += [Diagnostics.Stopwatch]::Frequency / 1000; $script:TestTick }
            # The recall reads the clock twice to record its write (1 ms); its phase is the 3 ms around it without it.
            Mock Save-OP2Recall { Add-OP2StorageWrite (Get-OP2Timestamp) }
            $seen = @{}
            Mock Save-OP2Delivery { $seen.Timing = $Timing }
            [void](ConvertTo-OPumper2Output @(New-OP2Completion) -Format json -Origin @{ Entered = 0 })
            "$($seen.Timing.RecallMs)|$($seen.Timing.FormatMs)|$($seen.Timing.Entered)" | Should -BeExactly '2|1|0'
            [void](ConvertTo-OPumper2Output @(New-OP2Completion) -Format json)
            $null -eq $seen.Timing['Entered'] | Should -BeTrue
        }
    }
    It 'times the callbacks alone, with the clock of every phase' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Executable = $script:OP2TestExecutable } {
            # The clock only moves inside the dispatch: 5 ms per batch.
            $script:TestTick = 0L; $script:Dispatches = 0
            Mock Get-OP2Timestamp { $script:TestTick }
            Mock Invoke-OP2Dispatch { $script:Dispatches++; $script:TestTick += 5 * [Diagnostics.Stopwatch]::Frequency / 1000 }
            $call = @{ Command = $Executable; ArgumentList = @('-NoProfile', '-Command', '"x"'); OnRecord = { param($record, $state) }; OnStdOut = $null; OnStdErr = $null
                State = $null; Complete = $null; WorkingDirectory = (Get-Location).Path; Environment = @{}; InputText = $null; StdOutDelimiter = "`n"; StdErrDelimiter = "`n"
                Encoding = 'utf-8'; SuccessExitCodes = @(0); TimeoutSeconds = 20; CancellationToken = [Threading.CancellationToken]::None; MaxRecordCharacters = 65536 }
            $completion = Invoke-OP2Native -Call $call -Configuration (Get-OP2Configuration)
            $script:Dispatches -gt 0 | Should -BeTrue
            $completion.Execution.Timing.CallbackMs | Should -Be (5 * $script:Dispatches)
        }
    }
    It 'opens and closes calls: the outermost starts a new account, and its entry expires with it' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $root = Enter-OP2Call 10
            try {
            "$($root.Account.StorageWrites.Count)|$($root.Account.PendingEntered)" | Should -BeExactly '0|10'
            $root.Account.StorageWrites.Add([pscustomobject]@{ At = 12L; Ms = 2.0 }); $root.Account.StorageWrites.Add([pscustomobject]@{ At = 9L; Ms = 4.0 })
            # A nested call keeps the account and the pending entry.
            $child = Enter-OP2Call 20
            [object]::ReferenceEquals($child.Parent, $root) | Should -BeTrue
            [object]::ReferenceEquals($child.Account, $root.Account) | Should -BeTrue
            "$($child.Account.StorageWrites.Count)|$($child.Account.PendingEntered)" | Should -BeExactly '2|10'
            "$(Get-OP2StorageDuration 10)|$(Get-OP2StorageDuration 12)|$(Get-OP2StorageDuration 13)|$(Get-OP2StorageDuration)" | Should -BeExactly '2|2|0|6'
            Exit-OP2Call $child
            [object]::ReferenceEquals($script:OP2CurrentCall, $root) | Should -BeTrue
            $root.Account.PendingEntered | Should -Be 10
            } finally { Exit-OP2Call $root }
            $null -eq $script:OP2CurrentCall | Should -BeTrue
            Get-OP2StorageDuration | Should -Be 0
            $next = Enter-OP2Call 30
            try { $next.Account.StorageWrites.Count | Should -Be 0 } finally { Exit-OP2Call $next }
        }
    }
    It 'loads the engine from a copy named by its content, leaving the built assembly free' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Directory = $TestDrive } {
            $assembly = Join-Path $script:OP2Root 'resources/runtime/FrenchExDev.OPumper2.Engine.dll'
            $shadow = Join-Path $Directory 'shadow'
            $copy = Import-OP2EngineAssembly $assembly $shadow
            $hash = (Get-FileHash -LiteralPath $assembly -Algorithm SHA256).Hash.Substring(0, 16)
            $copy | Should -BeExactly (Join-Path $shadow "$hash/FrenchExDev.OPumper2.Engine.dll")
            (Get-FileHash -LiteralPath $copy).Hash | Should -BeExactly (Get-FileHash -LiteralPath $assembly).Hash
            # A second import reuses the copy; a copy another import made first wins over this one's.
            $stamp = (Get-Item -LiteralPath $copy).LastWriteTimeUtc
            Import-OP2EngineAssembly $assembly $shadow | Should -BeExactly $copy
            (Get-Item -LiteralPath $copy).LastWriteTimeUtc | Should -Be $stamp
            Copy-OP2ShadowFile $assembly $copy
            @(Get-ChildItem -LiteralPath (Split-Path $copy)).Count | Should -Be 1
        }
    }
}
