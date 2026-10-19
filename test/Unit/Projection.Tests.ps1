BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Delivered lines' {
    It 'flattens whitespace and cuts long text at the canonical limit' {
        ConvertTo-OPumper2Line "  first`r`n`tsecond  " | Should -BeExactly 'first second'
        ConvertTo-OPumper2Line ('x'*400) | Should -BeExactly ('x'*400)
        ConvertTo-OPumper2Line ('y'+'x'*400) | Should -BeExactly ('y'+'x'*399+[char]0x2026)
        ConvertTo-OPumper2Line 'abcdef' -Limit 3 | Should -BeExactly ('abc'+[char]0x2026)
        ConvertTo-OPumper2Line $null | Should -BeExactly ''
        ConvertTo-OPumper2Line 'abcdef' -Limit 1 | Should -BeExactly ('a'+[char]0x2026)
        { ConvertTo-OPumper2Line 'abcdef' -Limit 0 } | Should -Throw
    }
}

Describe 'Projection limits' {
    It 'bounds each named collection by MaxItems and counts what it drops' {
        $projection = [ordered]@{ Name = 'x'; Items = @(1,2,3); Map = [ordered]@{ a = 1; b = 2; c = 3 }; Fixed = @(9,9) }
        $limited = Limit-OPumper2Projection $projection @('Items','Map','Absent') @{ MaxItems = 2 }
        ($limited.Items -join ',') | Should -BeExactly '1,2'
        $limited.Items.GetType().Name | Should -BeExactly 'List`1'
        (@($limited.Map.Keys) -join ',') | Should -BeExactly 'a,b'
        ($limited.Fixed -join ',') | Should -BeExactly '9,9'
        (@($limited.Omitted.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'Items=1,Map=1'
        (Limit-OPumper2Projection ([ordered]@{ Items = @(1,2,3) }) @('Items')).Contains('Omitted') | Should -BeFalse
        (Limit-OPumper2Projection ([ordered]@{ Items = @(1,2) }) @('Items') @{ MaxItems = 2 }).Contains('Omitted') | Should -BeFalse
        # A projection without collections, such as a quiet filter report, passes through.
        (@((Limit-OPumper2Projection ([ordered]@{ Lines = 4 }) @() @{ MaxItems = 1; MaxOutputBytes = 1 }).Keys) -join ',') | Should -BeExactly 'Lines'
    }
    It 'removes the last entries, in the order of the names, until the projection fits' {
        function Get-Size($value) { [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $value -Depth 40 -Compress)) }
        $full = [ordered]@{ First = @(('a'*40),('b'*40)); Second = @(('c'*40),('d'*40)) }
        $size = Get-Size $full
        $exact = Limit-OPumper2Projection ([ordered]@{ First = @(('a'*40),('b'*40)); Second = @(('c'*40),('d'*40)) }) @('Second','First') @{ MaxOutputBytes = $size }
        $exact.Contains('Omitted') | Should -BeFalse
        $tighter = Limit-OPumper2Projection ([ordered]@{ First = @(('a'*40),('b'*40)); Second = @(('c'*40),('d'*40)) }) @('Second','First') @{ MaxOutputBytes = ($size - 1) }
        ($tighter.Second -join ',') | Should -BeExactly ('c'*40)
        ($tighter.First -join ',') | Should -BeExactly (('a'*40)+','+('b'*40))
        $tighter.Omitted.Second | Should -Be 1
        $none = Limit-OPumper2Projection ([ordered]@{ First = @(('a'*40),('b'*40)); Second = @(('c'*40),('d'*40)) }) @('Second','First') @{ MaxOutputBytes = 0; Format = 'yaml' }
        "$($none.First.Count)|$($none.Second.Count)|$($none.Omitted.Second)|$($none.Omitted.First)" | Should -BeExactly '0|0|2|2'
    }
    It 'measures the projection inside the delivery it will be part of' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $data = [ordered]@{ Items = @('alpha','beta') }
            Measure-OP2Delivery $data @{} | Should -Be ([Text.Encoding]::UTF8.GetByteCount('{"Items":["alpha","beta"]}'))
            $envelope = New-OP2Completion -Outcome Failed -ErrorInfo (New-OP2Error 'Fixture' 'Test')
            $envelope.Capture = @{ Stdout = "one`ntwo"; Stderr = $null; Complete = $true; Lossy = $false }
            foreach ($compact in @($false, $true)) {
                $config = Get-OP2Configuration; $config.Envelope = $(if ($compact) { 'compact' } else { 'full' })
                $delivered = (Format-OP2Delivery @((New-OPumper2Result -Completion $envelope -Data $data)) yaml 20 8192 1 $config).Text
                Measure-OP2Delivery $data @{ Format = 'yaml'; Envelope = $envelope; ExcerptLines = 1; Compact = $compact } | Should -Be ([Text.Encoding]::UTF8.GetByteCount($delivered))
            }
        }
    }
    It 'fits a projection into the byte budget of its delivery' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $rows = @(1..200 | ForEach-Object { "row $_ " + ('x' * 40) })
            $result = New-OPumper2Result -Data ([ordered]@{ Rows = $rows }) -Projection { param($data, $settings) Limit-OPumper2Projection ([ordered]@{ Rows = @($data.Rows) }) @('Rows') $settings }
            foreach ($format in @('json','yaml')) {
                $text = (Format-OP2Delivery @($result) $format 500 2048 0 (Get-OP2Configuration)).Text
                [Text.Encoding]::UTF8.GetByteCount($text) | Should -BeLessOrEqual 2048
                $text | Should -Not -Match 'DataLimit'
                $text | Should -Match 'Omitted'
            }
        }
    }
}

Describe 'Route execution' {
    It 'runs a contract with the call settings and its own environment, exit codes and projection' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $script:RouteSeen = $null
            Mock Pump-Me {
                $script:RouteSeen = $PesterBoundParameters
                $completion = New-OP2Completion -Outcome Failed -Data @{ Explained = $true } -Execution @{ ExitCode = 2; InvocationIds = @() }
                $completion
            }
            $call = @{ Command = 'tool'; ArgumentList = @('verb'); WorkingDirectory = 'C:\work'; Environment = @{ KEEP = 'kept'; LANG = 'fr_FR' }; InputText = $null
                Encoding = 'utf-8'; SuccessExitCodes = @(0); TimeoutSeconds = 7; CancellationToken = [Threading.CancellationToken]::None; MaxRecordCharacters = 99 }
            $contract = [pscustomobject]@{ ArgumentList = @('verb','--flag'); Environment = @{ LANG = 'en_US.UTF-8' }; State = @{}; OnRecord = {}; Complete = {}; Projection = { param($d) 'projected' } }
            $result = Invoke-OPumper2Route -Call $call -Contract $contract -Explained { param($data) $data.Explained }
            "$($script:RouteSeen.Command)|$($script:RouteSeen.ArgumentList -join ' ')|$($script:RouteSeen.WorkingDirectory)|$($script:RouteSeen.TimeoutSeconds)|$($script:RouteSeen.MaxRecordCharacters)|$($script:RouteSeen.SuccessExitCodes -join ',')" |
                Should -BeExactly 'tool|verb --flag|C:\work|7|99|0'
            "$($script:RouteSeen.Environment.KEEP)|$($script:RouteSeen.Environment.LANG)" | Should -BeExactly 'kept|en_US.UTF-8'
            $script:RouteSeen.ContainsKey('InputText') | Should -BeFalse
            $script:RouteSeen.AsObject | Should -BeTrue
            $result.Presentation.ExcerptLines | Should -Be 0
            $result.Presentation.Projection | Should -Not -BeNullOrEmpty
            $call.InputText = 'stdin'
            $contract | Add-Member -NotePropertyName SuccessExitCodes -NotePropertyValue @(0,1)
            $kept = Invoke-OPumper2Route -Call $call -Contract $contract -Explained { param($data) $false }
            $script:RouteSeen.InputText | Should -BeExactly 'stdin'
            ($script:RouteSeen.SuccessExitCodes -join ',') | Should -BeExactly '0,1'
            $kept.Presentation.ExcerptLines | Should -BeNullOrEmpty
            (Invoke-OPumper2Route -Call $call -Contract $contract).Presentation.ExcerptLines | Should -BeNullOrEmpty
            # A contract without a batch callback, or with an empty one, runs its record callback; otherwise its batch one.
            "$($script:RouteSeen.ContainsKey('OnRecord'))|$($script:RouteSeen.ContainsKey('OnBatch'))" | Should -BeExactly 'True|False'
            $contract | Add-Member -NotePropertyName OnBatch -NotePropertyValue $null
            [void](Invoke-OPumper2Route -Call $call -Contract $contract)
            "$($script:RouteSeen.ContainsKey('OnRecord'))|$($script:RouteSeen.ContainsKey('OnBatch'))" | Should -BeExactly 'True|False'
            $batch = { param($records, $state) }
            $contract.OnBatch = $batch
            [void](Invoke-OPumper2Route -Call $call -Contract $contract)
            "$($script:RouteSeen.ContainsKey('OnRecord'))|$([object]::ReferenceEquals($script:RouteSeen.OnBatch, $batch))" | Should -BeExactly 'False|True'
        }
    }
}
