BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Phase durations of a native call' {
    It 'charges the import to the first delivery the session stores' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            # This suite imported the engine afresh: no delivery was stored yet.
            $script:OP2ImportPending | Should -BeTrue
            $script:OP2ImportMs -ge 0 | Should -BeTrue
        }
    }
    It 'times every phase of a call made through pump, and keeps them local' {
        $state = @{ Seen = 0 }
        $result = @(Invoke-TestChild '1..200 | ForEach-Object { "line $_" }' @{ State = $state; OnRecord = { param($record, $s) $s.Seen++ } })[-1]
        $state.Seen | Should -Be 200
        $timing = $result.Execution.Timing
        "$($timing.SetupMs -ge 0)|$($timing.ProcessMs -gt 0)|$($timing.CallbackMs -gt 0)|$($timing.BackpressureMs -ge 0)|$($timing.CompleteMs -ge 0)|$($timing.CaptureMs -ge 0)" | Should -BeExactly 'True|True|True|True|True|True'
        # The child runs longer than the whole call's setup, callbacks and capture together.
        $timing.ProcessMs -lt $result.Execution.ElapsedMs | Should -BeTrue
    }
    It 'times the setup of a routed call from the outer entry, its handler and contract included' {
        $handler = {
            param($call)
            # A slow contract: built before the handler's own pump call starts the child.
            Start-Sleep -Milliseconds 300
            $first = Pump-Me $call.Command -ArgumentList @('-NoProfile', '-Command', 'exit 0') -OnRecord { param($record, $state) } -AsObject
            $second = Pump-Me $call.Command -ArgumentList @('-NoProfile', '-Command', 'exit 0') -OnRecord { param($record, $state) } -AsObject
            [pscustomobject]@{ Kind = 'Completion'; First = $first.Execution.Timing.SetupMs; Second = $second.Execution.Timing.SetupMs }
        }
        Register-OPumper2 -Id op2.setup -Route @($script:OP2TestExecutable, 'op2-setup') -Handler $handler | Out-Null
        try {
            $timed = Pump-Me $script:OP2TestExecutable op2-setup -AsObject
            # The first native call takes the outer entry; the next one counts from its own.
            $timed.First -ge 300 | Should -BeTrue
            $timed.Second -lt 300 | Should -BeTrue
        } finally { Unregister-OPumper2 op2.setup | Out-Null }
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Executable = $script:OP2TestExecutable } {
            # Every call closed itself, a failing one included; the entry of the outermost expired with it.
            { Pump-Me pwsh -OnRecord {} -TimeoutSeconds -1 -AsObject } | Should -Throw '*Invalid execution*'
            $null -eq $script:OP2CurrentCall | Should -BeTrue
            # A new outermost call starts a new account of writes: its invocation's only.
            $state = @{ Scope = $null }
            $complete = { param($s,$execution) $s.Scope = & (Get-Module FrenchExDev.OPumper2.PoSh) { $script:OP2CurrentCall } }
            [void](Pump-Me $Executable -ArgumentList @('-NoProfile', '-Command', 'exit 0') -OnRecord {} -State $state -Complete $complete -AsObject)
            $first = $state.Scope
            [void](Pump-Me $Executable -ArgumentList @('-NoProfile', '-Command', 'exit 0') -OnRecord {} -State $state -Complete $complete -AsObject)
            [object]::ReferenceEquals($first.Account, $state.Scope.Account) | Should -BeFalse
            $first.Account.StorageWrites.Count | Should -Be 1
            $state.Scope.Account.StorageWrites.Count | Should -Be 1
        }
    }
    It 'leaves setup unmeasured for a call that did not enter through pump' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Executable = $script:OP2TestExecutable } {
            $call = @{ Command = $Executable; ArgumentList = @('-NoProfile', '-Command', 'exit 0'); OnRecord = { param($record, $state) }; OnStdOut = $null; OnStdErr = $null
                State = $null; Complete = $null; WorkingDirectory = (Get-Location).Path; Environment = @{}; InputText = $null; StdOutDelimiter = "`n"; StdErrDelimiter = "`n"
                Encoding = 'utf-8'; SuccessExitCodes = @(0); TimeoutSeconds = 20; CancellationToken = [Threading.CancellationToken]::None; MaxRecordCharacters = 65536 }
            $completion = Invoke-OP2Native -Call $call -Configuration (Get-OP2Configuration)
            $null -eq $completion.Execution.Timing.SetupMs | Should -BeTrue
            $completion.Execution.Timing.ProcessMs -gt 0 | Should -BeTrue
        }
    }
}
