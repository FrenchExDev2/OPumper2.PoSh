BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    function New-AuditDatabase {
        # A history of timed calls: one invocation (unless Linked is false) and one delivery (unless Local) per call,
        # counted with the configured tokenizer unless the call names another version.
        param([string]$Path, [hashtable[]]$Call)
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Database = $Path; Calls = $Call } {
            $config = Get-OP2Configuration; $config.DatabasePath = $Database
            Initialize-OP2Dependency
            $current = $script:OP2Tokenizers[$config.Tokenizer].Version
            foreach ($entry in $Calls) {
                $call = @{ route = $null; provider = $null; label = 'tool'; source = $null; output = $null; total = $null; process = $null; back = $null; callback = $null
                    records = $null; setup = $null; complete = $null; capture = $null; itokens = $null; recall = $null; format = $null; dtokens = $null; storage = $null; import = $null
                    version = $current; dversion = $null; local = $false }
                foreach ($key in $entry.get_Keys()) { $call[$key] = $entry[$key] }
                if ($null -eq $call.dversion) { $call.dversion = $call.version }
                Invoke-OP2Sql $config ('INSERT INTO invocations(id,timestamp,label,project,outcome,bytes,tokens,profile,version,complete,elapsed,setup_ms,process_ms,callback_ms,backpressure_ms,complete_ms,capture_ms,tokens_ms,records) ' +
                    "VALUES(@id,@time,@label,'p','Success',1,@source,'o200k_base',@version,1,1,@setup,@process,@callback,@back,@complete,@capture,@itokens,@records);") $call
                if ($call.local) { continue }
                Invoke-OP2Sql $config ('INSERT INTO deliveries(id,timestamp,bytes,tokens,profile,version,route,provider,total_ms,recall_ms,format_ms,tokens_ms,storage_ms,import_ms) ' +
                    "VALUES(@id,@time,1,@output,'o200k_base',@dversion,@route,@provider,@total,@recall,@format,@dtokens,@storage,@import); INSERT INTO delivery_invocations VALUES(@id,@id);") $call
            }
        }
    }
    function Invoke-TestAudit {
        # Runs a script block in the engine's scope, recreated there so it sees its private functions, with its history
        # (and configuration) pointed at test files.
        param([string]$Database, [scriptblock]$Body, [string]$Configuration)
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Database = $Database; Body = $Body; Configuration = $Configuration } {
            $previous = @{ Db = $script:OP2Environment.OPUMPER2_DB_PATH; Config = $script:OP2Environment.OPUMPER2_CONFIG_PATH }
            try {
                $script:OP2Environment.OPUMPER2_DB_PATH = $Database
                if ($Configuration) { $script:OP2Environment.OPUMPER2_CONFIG_PATH = $Configuration }
                & ([scriptblock]::Create($Body.ToString()))
            } finally { $script:OP2Environment.OPUMPER2_DB_PATH = $previous.Db; $script:OP2Environment.OPUMPER2_CONFIG_PATH = $previous.Config }
        }
    }
}

Describe 'Time audit' {
    BeforeAll {
        # Three timed calls and one stored before durations existed: two dotnet builds and a direct contract.
        $script:AuditDatabase = Join-Path $TestDrive 'audit.sqlite'
        New-AuditDatabase $script:AuditDatabase @(
            @{ id = 'a'; time = '2026-10-18T10:00:00.0000000Z'; route = 'dotnet.build'; provider = 'dotnet'; label = 'dotnet'; source = 10000; output = 400; total = 1500; process = 1000; back = 100; callback = 300; records = 2000; setup = 50; complete = 10; capture = 20; itokens = 30; recall = 40; format = 50; dtokens = 60; storage = 25; import = 200 }
            @{ id = 'b'; time = '2026-10-18T11:00:00.0000000Z'; route = 'dotnet.build'; provider = 'dotnet'; label = 'dotnet'; source = 6000; output = 600; total = 900; process = 800; back = 0; callback = 100; records = 1000; setup = 10; complete = 5; capture = 5; itokens = 10; recall = 10; format = 10; dtokens = 10; storage = 5 }
            @{ id = 'c'; time = '2026-10-19T09:00:00.0000000Z'; label = 'pwsh'; source = 100; output = 150; total = 300; process = 0; recall = 5; format = 5; dtokens = 5 }
        )
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Database = $script:AuditDatabase } {
            $config = Get-OP2Configuration; $config.DatabasePath = $Database
            Invoke-OP2Sql $config "INSERT INTO invocations(id,timestamp,label,project,outcome,bytes,tokens,profile,version,complete,elapsed) VALUES('old','2026-01-01T00:00:00Z','git','p','Success',1,9,'o200k_base','v',1,1); INSERT INTO deliveries(id,timestamp,bytes,tokens,profile,version) VALUES('old','2026-01-01T00:00:00Z',1,1,'o200k_base','v'); INSERT INTO delivery_invocations VALUES('old','old');"
        }
    }
    It 'charges each route its overhead, the waits it imposed included, against the tokens it saved' {
        Invoke-TestAudit $script:AuditDatabase {
            $audit = (Get-OPumper2Audit -AsObject).Data
            # Overheads: a = 1500 - 1000 + 100 = 600, b = 900 - 800 + 0 = 100, c = 300 (no child).
            $total = $audit.Total
            "$($total.Runs)|$($total.UnknownTokens)|$($total.SavedTokens)|$($total.OverheadMs)|$($total.P50Ms)|$($total.P95Ms)|$($total.BackpressureMs)|$($null -eq $total.SavedValue)" | Should -BeExactly '3|0|14950|1000|300|600|100|True'
            $total.CallbackMsPer1kLines | Should -Be (400 / 3000 * 1000)
            $total.TokensPerOverheadSecond | Should -Be 14950
            $audit.ImportMs | Should -Be 200
            ($audit.Groups | ForEach-Object { "$($_.Key)=$($_.Runs)/$($_.SavedTokens)/$($_.OverheadMs)" }) -join ',' | Should -BeExactly 'dotnet.build=2/15000/700,pwsh=1/-50/300'
            $audit.Groups[1].CallbackMsPer1kLines | Should -BeNullOrEmpty
            # Phases as shares of the 1000 ms of overhead: the tokens count the source's and the delivery's; the
            # callbacks are not a share, only the backpressure they caused; Other is what no phase measured.
            (@($audit.Phases.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Math]::Round($_.Value, 1))" }) -join ',') | Should -BeExactly 'Setup=6,Backpressure=10,Complete=1.5,Capture=2.5,Tokens=11.5,Recall=5.5,Format=6.5,Storage=3,Other=53.5'
            $audit.Local.Count | Should -Be 0
            ((Get-OPumper2Audit -GroupBy Provider -AsObject).Data.Groups | ForEach-Object Key) -join ',' | Should -BeExactly 'dotnet,(direct)'
            ((Get-OPumper2Audit -GroupBy Command -AsObject).Data.Groups | ForEach-Object Key) -join ',' | Should -BeExactly 'dotnet,pwsh'
            $recent = (Get-OPumper2Audit -Since ([datetime]'2026-10-19T00:00:00Z') -AsObject).Data
            "$($recent.Total.Runs)|$($recent.Since)" | Should -BeExactly "1|$(([datetime]'2026-10-19T00:00:00Z').ToUniversalTime().ToString('O'))"
            (Get-OPumper2Audit -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Data.Total.Runs | Should -Be 3
        }
    }
    It 'renders a Markdown page, and an empty history without dividing by zero' {
        Invoke-TestAudit $script:AuditDatabase {
            $page = Get-OPumper2Audit -AsMarkdown
            $page | Should -Match '(?m)^# OPumper2 audit\r?$'
            $page | Should -Match '3 runs \(0 without known tokens\), 14,950 tokens saved, 1\.0 s of overhead: 14,950 tokens saved per second of overhead\. Module import: 0\.2 s\.'
            $page | Should -Match '(?m)^\| dotnet\.build \| 2 \| 0 \| 15,000 \| 0\.7 \| 100 \| 600 \| 133\.3 \| 100 \| 21,429 \|\r?$'
            $page | Should -Match '(?m)^\| pwsh \| 1 \| 0 \| -50 \| 0\.3 \| 300 \| 300 \|  \| 0 \| -167 \|\r?$'
            $page | Should -Match 'Overhead by phase: Setup 6 %, Backpressure 10 %'
            $page | Should -Not -Match 'Local calls|Value saved'
            (Get-OPumper2Audit -Since ([datetime]'2026-10-19T00:00:00Z') -AsMarkdown) | Should -Match '(?m)^# OPumper2 audit since 2026-10-19'
        }
        Invoke-TestAudit (Join-Path $TestDrive 'empty.sqlite') {
            $none = (Get-OPumper2Audit -AsObject).Data
            "$($none.Total.Runs)|$($null -eq $none.Total.P50Ms)|$($null -eq $none.Total.TokensPerOverheadSecond)|$($none.Groups.Count)|$($none.Phases.Setup)|$($none.Phases.Other)" | Should -BeExactly '0|True|True|0|0|0'
        }
    }
    It 'saves nothing it cannot count: unknown source tokens and another tokenizer stay out of the savings' {
        $database = Join-Path $TestDrive 'unknown.sqlite'
        New-AuditDatabase $database @(
            @{ id = 'known'; time = '2026-10-18T10:00:00Z'; source = 1000; output = 100; total = 200; process = 100 }
            # A lossy capture has no exact count; an older tokenizer counted the other one.
            @{ id = 'lossy'; time = '2026-10-18T10:01:00Z'; output = 100; total = 400; process = 100 }
            @{ id = 'stale'; time = '2026-10-18T10:02:00Z'; source = 5000; output = 100; total = 600; process = 100; version = 'stale' }
            @{ id = 'mixed'; time = '2026-10-18T10:03:00Z'; source = 5000; output = 100; total = 600; process = 100; dversion = 'stale' }
            @{ id = 'empty'; time = '2026-10-18T10:04:00Z'; source = 5000; total = 600; process = 100 }
        )
        Invoke-TestAudit $database {
            $total = (Get-OPumper2Audit -AsObject).Data.Total
            # Only the known call saves (900 tokens), over its own 100 ms of overhead; every call's overhead counts.
            "$($total.Runs)|$($total.UnknownTokens)|$($total.SavedTokens)|$($total.OverheadMs)|$($total.TokensPerOverheadSecond)" | Should -BeExactly '5|4|900|1900|9000'
        }
    }
    It 'reports the local calls apart, and values the savings at the configured price' {
        $database = Join-Path $TestDrive 'local.sqlite'
        New-AuditDatabase $database @(
            @{ id = 'delivered'; time = '2026-10-18T10:00:00Z'; source = 3000000; output = 1000000; total = 2000; process = 1000 }
            @{ id = 'l1'; time = '2026-10-18T10:01:00Z'; label = 'git'; local = $true; process = 50; setup = 4; back = 6; complete = 1; capture = 2; itokens = 7; callback = 10; records = 100 }
            @{ id = 'l2'; time = '2026-10-18T10:02:00Z'; label = 'git'; local = $true; process = 50; setup = 10; records = 0 }
            # A call that never timed its child is not a measured local call.
            @{ id = 'l3'; time = '2026-10-18T10:03:00Z'; label = 'old'; local = $true }
        )
        $config = Join-Path $TestDrive 'priced.yaml'
        [IO.File]::WriteAllText($config, "general:`n  tokenPrice: 2.5`n  currency: EUR`n")
        Invoke-TestAudit $database -Configuration $config -Body {
            $audit = (Get-OPumper2Audit -AsObject).Data
            "$($audit.Total.SavedValue)|$($audit.Currency)|$($audit.Groups[0].SavedValue)" | Should -BeExactly '5|EUR|5'
            # Local overhead: the measured phases, 4 + 6 + 1 + 2 + 7 = 20 and 10.
            ($audit.Local | ForEach-Object { "$($_.Key)=$($_.Runs)/$($_.OverheadMs)/$($_.P95Ms)/$($_.CallbackMsPer1kLines)" }) -join ',' | Should -BeExactly 'git=2/30/20/100'
            $page = Get-OPumper2Audit -AsMarkdown
            $page | Should -Match 'Value saved: 5\.00 EUR\.'
            $page | Should -Match '(?m)^Local calls \(-AsObject, no delivery\):\r?$'
            $page | Should -Match '(?m)^\| git \| 2 \| 0\.0 \| 10 \| 20 \| 100\.0 \|\r?$'
        }
    }
    It 'ranks percentiles to the nearest value, and keeps fractions of a millisecond' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            "$(Get-OP2Percentile (1..101) 100)|$(Get-OP2Percentile (1..20) 95)|$(Get-OP2Percentile (1..20) 50)" | Should -BeExactly '101|19|10'
            # An overhead under a millisecond still yields a rate.
            $small = [pscustomobject]@{ OverheadMs = 0.5; SavedTokens = 10.0; Records = 0.0; CallbackMs = 0.0; BackpressureMs = 0.0 }
            (Measure-OP2AuditGroup 'small' @($small) $null).TokensPerOverheadSecond | Should -Be 20000
            $group = [ordered]@{ Key = 'big'; Runs = 1; UnknownTokens = 0; SavedTokens = 1.0; OverheadMs = 150000.0; P50Ms = 1.0; P95Ms = 1.0; CallbackMsPer1kLines = $null; BackpressureMs = 0.0; TokensPerOverheadSecond = 1.0; SavedValue = $null }
            $page = ConvertTo-OP2AuditMarkdown ([ordered]@{ Since = $null; GroupBy = 'Route'; Total = $group; Groups = @($group); Phases = [ordered]@{ Setup = 100.0 } })
            $page | Should -Match '(?m)^\| big \| 1 \| 0 \| 1 \| 150\.0 \|'
        }
    }
    It 'shares an overhead under a millisecond between its phases' {
        Invoke-TestAudit (Join-Path $TestDrive 'tiny.sqlite') {
            Invoke-OP2Sql (Get-OP2Configuration) "INSERT INTO deliveries(id,timestamp,bytes,tokens,profile,version,total_ms,recall_ms,format_ms) VALUES('t','2026-10-18T10:00:00Z',1,1,'o200k_base','v',0.5,0.25,0.25);"
            $phases = (Get-OPumper2Audit -AsObject).Data.Phases
            "$($phases.Recall)|$($phases.Format)|$($phases.Other)" | Should -BeExactly '50|50|0'
        }
    }
    It 'distinguishes no process from a missing duration, including partially timed multi-step calls' {
        $database = Join-Path $TestDrive 'unknown-duration.sqlite'
        New-AuditDatabase $database @(
            @{ id='known'; time='2026-10-19T10:00:00Z'; source=100; output=10; total=10; process=5 }
            @{ id='unknown'; time='2026-10-19T10:01:00Z'; source=200; output=10; total=100; setup=20 }
        )
        Invoke-TestAudit $database {
            $config = Get-OP2Configuration
            Invoke-OP2Sql $config "INSERT INTO delivery_invocations VALUES('unknown','known'); INSERT INTO deliveries(id,timestamp,bytes,tokens,profile,version,total_ms,format_ms) VALUES('no-child','2026-10-19T10:02:00Z',1,1,'o200k_base','v',2,2);"
            $audit = (Get-OPumper2Audit -AsObject).Data
            $audit.Total.UnknownDurations | Should -Be 1
            "$($audit.Total.OverheadMs)|$($audit.Total.P50Ms)|$($audit.Total.P95Ms)" | Should -BeExactly '7|2|5'
            # Only the known native call supplies both a saving and an overhead for the rate.
            $audit.Total.TokensPerOverheadSecond | Should -Be 18000
            $audit.Phases.Format | Should -Be (2 / 7 * 100)
            (Get-OPumper2Audit -AsMarkdown) | Should -Match '1 runs have unknown process durations; overhead statistics exclude them'
        }
    }
}
