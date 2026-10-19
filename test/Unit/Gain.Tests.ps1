BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    function New-GainRow {
        # A delivery row as the history query returns it.
        param([string]$Timestamp = '2026-10-12T12:00:00.0000000Z', [string]$Route, [string]$Label = 'tool', [string]$Provider, [string]$Format = 'yaml',
            [string]$Outcome = 'Success', [string]$Truncation, [string]$Session, [string]$Fingerprint, [string]$Project = 'P', [string]$Database = 'db',
            [long]$SourceBytes = 100, [object]$SourceTokens = 40, [long]$OutputBytes = 10, [object]$OutputTokens = 4,
            [object]$DataTokens = $null, [object]$RecordTokens = 0, [object]$ExcerptTokens = 0, [string]$AlternateFormat, [object]$AlternateTokens = $null,
            [int]$Complete = 1, [int]$UnknownTokens = 0, [double]$ElapsedMs = 1, [bool]$Rerun = $false, [string]$RecallId, [int]$RecallReads = 0)
        [pscustomobject]@{ Id = [guid]::NewGuid().ToString('N'); Timestamp = $Timestamp; Route = $Route; Label = $Label; Provider = $Provider; Format = $Format
            Outcome = $Outcome; Truncation = $Truncation; Session = $Session; Fingerprint = $Fingerprint; Project = $Project; Database = $Database
            SourceBytes = $SourceBytes; SourceTokens = $SourceTokens; OutputBytes = $OutputBytes; OutputTokens = $OutputTokens; DataTokens = $DataTokens
            RecordTokens = $RecordTokens; ExcerptTokens = $ExcerptTokens; AlternateFormat = $AlternateFormat; AlternateTokens = $AlternateTokens
            Complete = $Complete; UnknownTokens = $UnknownTokens; ElapsedMs = $ElapsedMs; Rerun = $Rerun; RecallId = $RecallId; RecallReads = $RecallReads }
    }
    function New-AdviceGroup {
        param([string]$Key = 'tool', [long]$Compared = 3, [long]$TokenCompared = 3, [object]$SavedTokens = 10, [double]$RerunRate = 0, [long]$Stored = 0, [double]$RecallRate = 0, [double]$LossyRate = 0,
            [object]$Layers = $null, [object]$Alternate = $null)
        [pscustomobject]@{ Key = $Key; Compared = $Compared; TokenCompared = $TokenCompared; SavedTokens = $SavedTokens; RerunRate = $RerunRate; Stored = $Stored; RecallRate = $RecallRate
            LossyRate = $LossyRate; Layers = $Layers; Alternate = $Alternate }
    }
    function Add-GainDelivery {
        # Inserts one delivery and its invocation into a history database.
        param([hashtable]$Config, [string]$Timestamp, [string]$Route, [string]$Provider, [string]$Format = 'yaml', [string]$Outcome = 'Success',
            [string]$Session, [string]$Project = 'p1', [long]$SourceBytes, [long]$SourceTokens, [long]$OutputBytes, [long]$OutputTokens, [string]$Label = 'tool')
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Config=$Config;Values=$PSBoundParameters;Directory=$TestDrive} {
            Initialize-OP2Dependency
            $id = [guid]::NewGuid().ToString('N')
            Invoke-OP2Sql $Config ("INSERT INTO invocations(id,timestamp,label,project,outcome,bytes,tokens,profile,version,complete,elapsed,session) VALUES(@id,@timestamp,@label,@project,@outcome,@sourceBytes,@sourceTokens,@profile,@version,1,2,@session);" +
                'INSERT INTO deliveries(id,timestamp,bytes,tokens,profile,version,route,provider,format,outcome,session) VALUES(@id,@timestamp,@outputBytes,@outputTokens,@profile,@version,@route,@provider,@format,@outcome,@session);' +
                'INSERT INTO delivery_invocations VALUES(@id,@id);') @{ id = $id; timestamp = $Values.Timestamp; label = $(if ($Values.ContainsKey('Label')) { $Values.Label } else { 'tool' })
                project = Get-OP2ProjectHash (Join-Path $Directory $(if ($Values.ContainsKey('Project')) { $Values.Project } else { 'p1' }))
                outcome = $(if ($Values.ContainsKey('Outcome')) { $Values.Outcome } else { 'Success' }); sourceBytes = $Values.SourceBytes; sourceTokens = $Values.SourceTokens
                outputBytes = $Values.OutputBytes; outputTokens = $Values.OutputTokens; route = $Values['Route']; provider = $Values['Provider']
                format = $(if ($Values.ContainsKey('Format')) { $Values.Format } else { 'yaml' }); session = $Values['Session']
                profile = $Config.Tokenizer; version = $script:OP2Tokenizers[$Config.Tokenizer].Version }
        }
    }
}

Describe 'Gain measures' {
    It 'weighs volumes, token pairs, recalls, losses, delivered composition and the alternate format' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Rows=@(
            (New-GainRow -SourceBytes 100 -SourceTokens 40 -OutputBytes 10 -OutputTokens 6 -DataTokens 2 -RecordTokens 1 -ExcerptTokens 1 -AlternateFormat json -AlternateTokens 3 -Truncation 'ItemLimit' -Rerun $true -RecallId r1 -RecallReads 2 -ElapsedMs 5),
            (New-GainRow -SourceBytes 200 -SourceTokens 80 -OutputBytes 50 -OutputTokens 20 -ElapsedMs 7 -RecallId r2),
            (New-GainRow -SourceBytes 50 -SourceTokens $null -OutputBytes 5 -OutputTokens 2 -UnknownTokens 1),
            (New-GainRow -SourceBytes 30 -SourceTokens 10 -OutputBytes 3 -OutputTokens $null))} {
            $measure = Measure-OP2Gain $Rows
            (@($measure.Keys) -join ',') | Should -BeExactly 'Compared,TokenCompared,SourceBytes,OutputBytes,SavedBytes,Rate,SourceTokens,OutputTokens,SavedTokens,TokenRate,Reruns,RerunRate,Stored,Recalled,RecallRate,Lossy,LossyRate,ElapsedMs,Layers,Alternate'
            $measure.Compared | Should -Be 4
            $measure.TokenCompared | Should -Be 2
            $measure.SourceBytes | Should -Be 380
            $measure.OutputBytes | Should -Be 68
            $measure.SavedBytes | Should -Be 312
            $measure.Rate | Should -Be (312/380)
            $measure.SourceTokens | Should -Be 120
            $measure.OutputTokens | Should -Be 26
            $measure.SavedTokens | Should -Be 94
            $measure.TokenRate | Should -Be (94/120)
            $measure.Reruns | Should -Be 1
            $measure.RerunRate | Should -Be 0.25
            $measure.Stored | Should -Be 2
            $measure.Recalled | Should -Be 1
            $measure.RecallRate | Should -Be 0.5
            $measure.Lossy | Should -Be 1
            $measure.LossyRate | Should -Be 0.25
            $measure.ElapsedMs | Should -Be 14
            (@($measure.Layers.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'Envelope=2,Data=2,Records=1,Excerpt=1'
            (@($measure.Alternate.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'Format=json,Compared=1,Delivered=6,Tokens=3,Rate=0.5'
            $empty = Measure-OP2Gain @()
            $empty.Compared | Should -Be 0
            foreach ($name in @('Rate','SourceTokens','OutputTokens','SavedTokens','TokenRate','RerunRate','RecallRate','LossyRate','Layers','Alternate')) { $empty[$name] | Should -BeNullOrEmpty }
            $empty.SourceBytes | Should -Be 0
            $empty.Reruns | Should -Be 0
            $empty.Stored | Should -Be 0
            $empty.Lossy | Should -Be 0
        }
    }
    It 'marks a delivery of the same command line within the rerun window of the same history' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Rows=@(
            (New-GainRow -Timestamp '2026-10-12T12:00:00.0000000Z' -Fingerprint F),
            (New-GainRow -Timestamp '2026-10-12T12:30:00.0000000Z' -Fingerprint F),
            (New-GainRow -Timestamp '2026-10-12T13:01:00.0000000Z' -Fingerprint F),
            (New-GainRow -Timestamp '2026-10-12T13:02:00.0000000Z' -Fingerprint F -Database other),
            (New-GainRow -Timestamp '2026-10-12T13:03:00.0000000Z' -Fingerprint G),
            (New-GainRow -Timestamp '2026-10-12T13:04:00.0000000Z'))} {
            Add-OP2GainRerun $Rows 30
            (@($Rows | ForEach-Object Rerun) -join ',') | Should -BeExactly 'False,True,False,False,False,False'
            Add-OP2GainRerun $Rows 31
            (@($Rows | ForEach-Object Rerun) -join ',') | Should -BeExactly 'False,True,True,False,False,False'
        }
    }
    It 'keys rows by command, context and local period, alone or combined' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Row=(New-GainRow -Route r -Label l -Provider p -Format json -Outcome Failed -Session s -Project P)} {
            $expected = @{ Command='r'; Route='r'; Provider='p'; Format='json'; Outcome='Failed'; Session='s'; Project='P'; Day='2026-10-12'; Week='2026-W42'; Month='2026-10' }
            foreach ($name in $script:OP2GainKeys.Keys) { Get-OP2GainKey $Row @($name) | Should -BeExactly $expected[$name] }
            Get-OP2GainKey $Row @('Provider','Format') | Should -BeExactly 'p | json'
            $Row.Route = ''
            Get-OP2GainKey $Row @('Command') | Should -BeExactly 'l'
            Get-OP2GainKey $Row @('Route','Outcome') | Should -BeExactly '(none) | Failed'
            $valid = ((Get-Command Get-OPumper2Gain).Parameters.GroupBy.Attributes | Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] }).ValidValues
            ($valid -join ',') | Should -BeExactly (@($script:OP2GainKeys.Keys) -join ',')
        }
    }
    It 'orders command groups by savings and other groups by key' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Rows=@(
            (New-GainRow -Label a -SourceBytes 100 -OutputBytes 10 -Timestamp '2026-10-13T12:00:00.0000000Z'),
            (New-GainRow -Label b -SourceBytes 200 -OutputBytes 10 -Timestamp '2026-10-12T12:00:00.0000000Z'),
            (New-GainRow -Label c -SourceBytes 100 -OutputBytes 10 -Timestamp '2026-10-14T12:00:00.0000000Z'),
            (New-GainRow -Label b -SourceBytes 50 -OutputBytes 10 -Timestamp '2026-10-12T13:00:00.0000000Z'))} {
            (@(Get-OP2GainGroup $Rows @('Command') | ForEach-Object { "$($_.Key)=$($_.Compared)/$($_.SavedBytes)" }) -join ',') | Should -BeExactly 'b=2/230,a=1/90,c=1/90'
            (@(Get-OP2GainGroup $Rows @('Day') | ForEach-Object Key) -join ',') | Should -BeExactly '2026-10-12,2026-10-13,2026-10-14'
            (@(Get-OP2GainGroup $Rows @('Command','Day') | ForEach-Object Key) -join ',') | Should -BeExactly 'b | 2026-10-12,a | 2026-10-13,c | 2026-10-14'
            @(Get-OP2GainGroup @() @('Command')).Count | Should -Be 0
        }
    }
    It 'ranks the largest savings and losses among deliveries with known tokens' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Rows=@(
            (New-GainRow -Label small -SourceTokens 10 -OutputTokens 5 -Route route -Truncation 'DataLimit' -Rerun $true -RecallId abc),
            (New-GainRow -Label large -SourceTokens 100 -OutputTokens 5),
            (New-GainRow -Label loss -SourceTokens 10 -OutputTokens 50 -Complete 0),
            (New-GainRow -Label unknown -SourceTokens $null -OutputTokens 1 -UnknownTokens 1))} {
            (@(Select-OP2GainEntry $Rows 2 -Descending | ForEach-Object Command) -join ',') | Should -BeExactly 'large,route'
            (@(Select-OP2GainEntry $Rows 1 | ForEach-Object Command) -join ',') | Should -BeExactly 'loss'
            $entry = ConvertTo-OP2GainEntry $Rows[0]
            (@($entry.PSObject.Properties.Name) -join ',') | Should -BeExactly 'Timestamp,Command,Format,Outcome,Rerun,Recall,Compared,Truncation,SourceTokens,OutputTokens,SavedTokens,TokenRate,SourceBytes,OutputBytes'
            $entry.Command | Should -Be 'route'
            $entry.Rerun | Should -BeTrue
            $entry.Recall | Should -BeExactly 'abc'
            $entry.Compared | Should -BeTrue
            $entry.Truncation | Should -Be 'DataLimit'
            $entry.SavedTokens | Should -Be 5
            (ConvertTo-OP2GainEntry $Rows[2]).Compared | Should -BeFalse
        }
    }
    It 'charts the saved tokens of the last thirty local days' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Rows=@(
            (New-GainRow -Timestamp '2026-10-31T12:00:00.0000000Z' -SourceTokens 14 -OutputTokens 4),
            (New-GainRow -Timestamp '2026-10-02T12:00:00.0000000Z' -SourceTokens 24 -OutputTokens 4),
            (New-GainRow -Timestamp '2026-10-03T12:00:00.0000000Z' -SourceTokens 4 -OutputTokens 9),
            (New-GainRow -Timestamp '2026-10-01T12:00:00.0000000Z' -SourceTokens 99 -OutputTokens 4),
            (New-GainRow -Timestamp '2026-10-31T13:00:00.0000000Z' -SourceTokens $null -OutputTokens 4 -UnknownTokens 1))} {
            $graph = Get-OP2GainGraph $Rows ([datetime]'2026-10-31')
            $graph.Count | Should -Be 30
            "$($graph[0].Day)=$($graph[0].SavedTokens)" | Should -BeExactly '2026-10-02=20'
            "$($graph[1].Day)=$($graph[1].SavedTokens)" | Should -BeExactly '2026-10-03=-5'
            "$($graph[-1].Day)=$($graph[-1].SavedTokens)" | Should -BeExactly '2026-10-31=10'
            @($graph | Where-Object SavedTokens -EQ 0).Count | Should -Be 27
            $lines = (Format-OP2GainGraph $graph) -split "`n"
            $lines[0] | Should -BeExactly 'Saved tokens per day'
            $lines[1] | Should -BeExactly ('2026-10-02 ' + ('#' * 40) + ' 20')
            $lines[2] | Should -BeExactly ('2026-10-03 ' + (' ' * 40) + ' -5')
            $lines[-1] | Should -BeExactly ('2026-10-31 ' + ('#' * 20).PadRight(40) + ' 10')
            $flat = (Format-OP2GainGraph @([pscustomobject]@{Day='d';SavedTokens=0})) -split "`n"
            $flat[1] | Should -BeExactly ('d ' + (' ' * 40) + ' 0')
            $one = (Format-OP2GainGraph @([pscustomobject]@{Day='d';SavedTokens=1})) -split "`n"
            $one[1] | Should -BeExactly ('d ' + ('#' * 40) + ' 1')
        }
    }
    It 'values the history and its monthly share when a price and a budget are configured' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Rows=@(
            (New-GainRow -Timestamp '2026-10-20T12:00:00.0000000Z' -SourceTokens 1000000 -OutputTokens 100000),
            (New-GainRow -Timestamp '2026-09-20T12:00:00.0000000Z' -SourceTokens 500 -OutputTokens 100))} {
            $config = Get-OP2Configuration
            Get-OP2GainCost (Measure-OP2Gain $Rows) $config | Should -BeNullOrEmpty
            Get-OP2GainQuota $Rows $config ([datetime]'2026-10-31') | Should -BeNullOrEmpty
            $config.TokenPrice = 3; $config.Currency = 'EUR'; $config.MonthlyTokenBudget = 1800000
            $cost = Get-OP2GainCost (Measure-OP2Gain @($Rows[0])) $config
            (@($cost.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'Currency=EUR,TokenPrice=3,Captured=3,Delivered=0.3,Saved=2.7'
            $quota = Get-OP2GainQuota $Rows $config ([datetime]'2026-10-31')
            (@($quota.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'Month=2026-10,Tier=,Budget=1800000,SavedTokens=900000,Share=0.5'
            $none = Get-OP2GainQuota $Rows $config ([datetime]'2026-08-31')
            $none.SavedTokens | Should -BeNullOrEmpty
            $none.Share | Should -BeNullOrEmpty
            $none.Tier | Should -BeNullOrEmpty
            $config.QuotaTiers = @{ pro = 900000; max = 3600000 }
            $tier = Get-OP2GainQuota $Rows $config ([datetime]'2026-10-31') -Tier max
            "$($tier.Tier)|$($tier.Budget)|$($tier.Share)" | Should -BeExactly 'max|3600000|0.25'
            $config.QuotaTier = 'pro'; $config.MonthlyTokenBudget = $null
            "$((Get-OP2GainQuota $Rows $config ([datetime]'2026-10-31')).Tier)|$((Get-OP2GainQuota $Rows $config ([datetime]'2026-10-31')).Share)" | Should -BeExactly 'pro|1'
            { Get-OP2GainQuota $Rows $config -Tier missing } | Should -Throw '*Unknown quota tier: missing.*'
        }
    }
}

Describe 'Gain advice' {
    It 'advises from three deliveries of a command, at each rule threshold' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Groups=@(
            (New-AdviceGroup -Key negative -SavedTokens -1),
            (New-AdviceGroup -Key 'negative-few' -TokenCompared 2 -SavedTokens -1),
            (New-AdviceGroup -Key neutral -SavedTokens 0),
            (New-AdviceGroup -Key rerun -RerunRate 0.2),
            (New-AdviceGroup -Key 'rerun-low' -RerunRate 0.19),
            (New-AdviceGroup -Key 'rerun-few' -Compared 2 -RerunRate 1),
            (New-AdviceGroup -Key recall -Stored 3 -RecallRate 0.2),
            (New-AdviceGroup -Key 'recall-low' -Stored 3 -RecallRate 0.19),
            (New-AdviceGroup -Key 'recall-few' -Stored 2 -RecallRate 1),
            (New-AdviceGroup -Key lossy -LossyRate 0.2),
            (New-AdviceGroup -Key 'lossy-low' -LossyRate 0.19),
            (New-AdviceGroup -Key 'lossy-few' -Compared 2 -LossyRate 1),
            (New-AdviceGroup -Key excerpt -Layers ([ordered]@{Envelope=1;Data=4;Records=0;Excerpt=5})),
            (New-AdviceGroup -Key 'excerpt-even' -Layers ([ordered]@{Envelope=1;Data=4;Records=0;Excerpt=4})),
            (New-AdviceGroup -Key 'excerpt-few' -Compared 2 -Layers ([ordered]@{Envelope=1;Data=0;Records=0;Excerpt=5})),
            (New-AdviceGroup -Key format -Alternate ([ordered]@{Format='json';Compared=3;Delivered=10;Tokens=9;Rate=0.1})),
            (New-AdviceGroup -Key 'format-low' -Alternate ([ordered]@{Format='json';Compared=3;Delivered=100;Tokens=91;Rate=0.09})),
            (New-AdviceGroup -Key 'format-few' -Alternate ([ordered]@{Format='json';Compared=2;Delivered=10;Tokens=1;Rate=0.9})))} {
            $advice = @(Get-OP2GainAdvice $Groups)
            (@($advice | ForEach-Object { "$($_.Command):$($_.Rule)" }) -join ',') | Should -BeExactly 'negative:NegativeSavings,rerun:FrequentRerun,recall:FrequentRecall,lossy:LossyDelivery,excerpt:ExcerptHeavy,format:CheaperFormat'
            $advice[0].Advice | Should -BeExactly 'negative costs 1 more tokens than its native output over 3 deliveries: deliver a smaller projection, or lower MaxItems and ExcerptLines.'
            $advice[1].Advice | Should -BeExactly 'rerun is run again within the rerun window after 20.0 % of its deliveries: its delivery probably misses information.'
            $advice[2].Advice | Should -BeExactly 'recall is read back from the recall store after 20.0 % of its deliveries: deliver what is read back.'
            $advice[3].Advice | Should -BeExactly 'lossy is truncated in 20.0 % of its deliveries: raise MaxOutputBytes or narrow the request.'
            $advice[4].Advice | Should -BeExactly 'excerpt delivers more failure excerpt than Data: a contract or route that parses its failures would replace raw lines.'
            $advice[5].Advice | Should -BeExactly 'format would be 10.0 % smaller in json.'
        }
    }
}

Describe 'Gain rendering' {
    It 'formats counts and rates for people' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            (@($null, 999, 1000, 1234, -1500, 999999, 1000000, 2500000) | ForEach-Object { Format-OP2GainCount $_ }) -join ',' | Should -BeExactly '-,999,1k,1.2k,-1.5k,1000k,1M,2.5M'
            Format-OP2GainRate $null | Should -BeExactly '-'
            Format-OP2GainRate 0.25 | Should -BeExactly '25.0 %'
        }
    }
}

Describe 'Gain reports' {
    BeforeAll {
        $script:First = InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Path=(Join-Path $TestDrive 'first.sqlite')} { $c=Get-OP2Configuration; $c.DatabasePath=$Path; $c }
        $script:Second = InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Path=(Join-Path $TestDrive 'second.sqlite')} { $c=Get-OP2Configuration; $c.DatabasePath=$Path; $c }
        $today = [DateTime]::UtcNow.Date.AddHours(12).ToString('O')
        Add-GainDelivery $script:First -Timestamp '2026-10-12T12:00:00.0000000Z' -Route 'git.status' -Provider git -SourceBytes 1000 -SourceTokens 400 -OutputBytes 100 -OutputTokens 40 -Session s1
        Add-GainDelivery $script:First -Timestamp '2026-10-13T12:00:00.0000000Z' -Label dotnet -Format json -Outcome Failed -SourceBytes 500 -SourceTokens 200 -OutputBytes 50 -OutputTokens 20 -Session s2 -Project p2
        Add-GainDelivery $script:Second -Timestamp $today -Route 'git.status' -Provider git -SourceBytes 300 -SourceTokens 100 -OutputBytes 30 -OutputTokens 10 -Session s1
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Config=$script:First} {
            Invoke-OP2Sql $Config "INSERT INTO invocations(id,timestamp,label,project,outcome,bytes,tokens,profile,version,complete,elapsed) VALUES('local',@time,'tool','p','Success',70,7,@profile,@version,1,1);" @{time=[DateTime]::UtcNow.ToString('O');profile=$Config.Tokenizer;version=$script:OP2Tokenizers[$Config.Tokenizer].Version}
        }
    }
    It 'reports an absent history as empty, with no list unless asked' {
        $absent = Join-Path $TestDrive 'absent-gain.sqlite'
        foreach ($data in @((Get-OPumper2Gain -DatabasePath $absent -AsObject).Data, (Get-OPumper2Gain -DatabasePath $absent -History 0 -Top 0 -Worst 0 -AsObject).Data)) {
            "$($data.Deliveries)|$($data.Local.Invocations)|$($data.Local.SourceBytes)|$($data.Local.SourceTokens)" | Should -BeExactly '0|0|0|0'
            "$($data.Contains('History'))|$($data.Contains('Top'))|$($data.Contains('Worst'))" | Should -BeExactly 'False|False|False'
        }
        Test-Path -LiteralPath $absent | Should -BeFalse
    }
    It 'reads several histories with their filters and local objects' {
        $data = (Get-OPumper2Gain -DatabasePath $script:First.DatabasePath,$script:Second.DatabasePath -GroupBy Provider,Format -AsObject).Data
        ($data.Databases -join ',') | Should -BeExactly "$($script:First.DatabasePath),$($script:Second.DatabasePath)"
        $data.Deliveries | Should -Be 3
        $data.SourceTokens | Should -Be 700
        $data.OutputTokens | Should -Be 70
        (@($data.Local.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') | Should -BeExactly 'Invocations=1,SourceBytes=70,SourceTokens=7'
        (@($data.Groups | ForEach-Object { "$($_.Key)=$($_.SourceTokens)" }) -join ',') | Should -BeExactly '(none) | json=200,git | yaml=500'
        (Get-OPumper2Gain -DatabasePath $script:First.DatabasePath -Session s2 -AsObject).Data.SourceTokens | Should -Be 200
        Push-Location $TestDrive
        try { (Get-OPumper2Gain -DatabasePath 'first.sqlite' -Project 'p2' -AsObject).Data.Deliveries | Should -Be 1 }
        finally { Pop-Location }
        (Get-OPumper2Gain -DatabasePath $script:First.DatabasePath -Since ([datetime]'2026-10-13T00:00:00Z') -AsObject).Data.Deliveries | Should -Be 1
        (Get-OPumper2Gain -DatabasePath $script:First.DatabasePath,(Join-Path $TestDrive 'absent.sqlite') -AsObject).Data.Deliveries | Should -Be 2
        Test-Path -LiteralPath (Join-Path $TestDrive 'absent.sqlite') | Should -BeFalse
        $plain = (Get-OPumper2Gain -DatabasePath $script:First.DatabasePath -History 0 -Top 0 -Worst 0 -AsObject).Data
        foreach ($name in @('Groups','History','Top','Worst','Graph','Cost','Quota','Advice')) { $plain.Contains($name) | Should -BeFalse }
        (Get-OPumper2Gain -DatabasePath $script:First.DatabasePath -AsObject).Data.Contains('History') | Should -BeFalse
    }
    It 'renders the report as text, CSV, a status line, YAML or JSON' {
        $databases = @($script:First.DatabasePath,$script:Second.DatabasePath)
        $text = Get-OPumper2Gain -DatabasePath $databases -GroupBy Command -Top 1 -Worst 1 -History 1 -Graph -AsText
        $text | Should -Match '^OPumper2 gain, o200k_base tokens \(Microsoft\.ML\.Tokenizers/2\.0\.0\), '
        $text | Should -Match 'Total\s+3\s+700\s+70\s+630\s+90\.0 %\s+90\.0 %\s+0\s+0\s+0'
        $text | Should -Match 'git\.status\s+2\s+500\s+50\s+450'
        $text | Should -Match 'Local objects never delivered: 1 calls, 7 tokens kept out of context\.'
        $text | Should -Match '(?m)^Top$'
        $text | Should -Match '(?m)^Worst$'
        $text | Should -Match '(?m)^History$'
        $text | Should -Match '(?m)^Saved tokens per day$'
        $text | Should -Not -Match 'Delivered tokens:|Value at|Monthly budget|Advice'
        $csv = (Get-OPumper2Gain -DatabasePath $databases -GroupBy Command -AsCsv) -split "`n"
        $csv[0] | Should -BeExactly '"Key","Deliveries","Captured","Delivered","Saved","Save%","Bytes saved%","Reruns","Recalled","Lossy"'
        $csv[1] | Should -BeExactly '"Total","3","700","70","630","90.0 %","90.0 %","0","0","0"'
        $csv.Count | Should -Be 4
        Get-OPumper2Gain -DatabasePath $databases -AsLine | Should -BeExactly 'OPumper2: 630 tokens saved (90.0 %), 3 deliveries, 0 reruns, 0 recalls'
        (Get-OPumper2Gain -DatabasePath $databases -AsJson | ConvertFrom-Json)[0].Data.Deliveries | Should -Be 3
        Get-OPumper2Gain -DatabasePath $databases -AsYaml | Should -Match 'Deliveries: 3'
    }
    It 'renders composition, alternate format, valuation, quota and advice when the history holds them' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Row=(New-GainRow -SourceTokens 2000 -OutputTokens 1500 -DataTokens 1000 -RecordTokens 100 -ExcerptTokens 50 -AlternateFormat json -AlternateTokens 1200)} {
            $data = [ordered]@{ Profile = 'p'; CounterVersion = 'v'; Databases = @('a','b'); Deliveries = 1 }
            $measure = Measure-OP2Gain @($Row)
            foreach ($name in $measure.Keys) { $data[$name] = $measure[$name] }
            $data.Local = [ordered]@{ Invocations = 2; SourceBytes = 10; SourceTokens = 2500 }
            $data.Cost = [ordered]@{ Currency = 'EUR'; TokenPrice = 3; Captured = 0.006; Delivered = 0.0045; Saved = 0.0015 }
            $data.Quota = [ordered]@{ Month = '2026-10'; Budget = 1000000; SavedTokens = 250000; Share = 0.25 }
            $data.Advice = @([pscustomobject]@{ Command = 'x'; Rule = 'r'; Advice = 'x advice' })
            $text = ConvertTo-OP2GainText ([pscustomobject]@{ Outcome = 'Success'; Data = $data })
            $text | Should -Match 'OPumper2 gain, p tokens \(v\), a, b'
            $text | Should -Match 'Local objects never delivered: 2 calls, 2\.5k tokens kept out of context\.'
            $text | Should -Match 'Delivered tokens: envelope 350, Data 1k, records 100, excerpt 50\.'
            $text | Should -Match 'In json: 1\.2k tokens instead of 1\.5k \(20\.0 % smaller\)\.'
            $text | Should -Match 'Value at 3 EUR per million tokens: captured 0\.006, delivered 0\.0045, saved 0\.0015\.'
            $text | Should -Match 'Monthly budget 2026-10: 250k of 1M tokens saved \(25\.0 %\)\.'
            $data.Quota.Tier = 'pro'
            ConvertTo-OP2GainText ([pscustomobject]@{ Outcome = 'Success'; Data = $data }) | Should -Match 'Monthly budget 2026-10 \(pro\): 250k'
            $text | Should -Match "Advice`n- x advice"
        }
    }
    It 'adds the configured valuation and the advice to the report' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive;First=$script:First.DatabasePath} {
            $path = Join-Path $Directory 'valued.yaml'
            [IO.File]::WriteAllText($path, "general:`n  timeoutSeconds: 20`n  tokenPrice: 1`n  monthlyTokenBudget: 1000`n  quotaTiers:`n    pro: 2000")
            $previous = $script:OP2Environment.OPUMPER2_CONFIG_PATH
            try {
                $script:OP2Environment.OPUMPER2_CONFIG_PATH = $path
                $data = (Get-OPumper2Gain -DatabasePath $First -AsObject).Data
                $data.Cost.Saved | Should -Be 0.00054
                $data.Quota.Budget | Should -Be 1000
                (Get-OPumper2Gain -DatabasePath $First -Tier pro -AsObject).Data.Quota.Budget | Should -Be 2000
                (Get-OPumper2Gain -DatabasePath $First -Tier missing -AsObject).Outcome | Should -Be 'Failed'
            } finally { $script:OP2Environment.OPUMPER2_CONFIG_PATH = $previous }
            Mock Get-OP2GainAdvice { [pscustomobject]@{ Command = 'x'; Rule = 'r'; Advice = 'x advice' } }
            (Get-OPumper2Gain -DatabasePath $First -AsObject).Data.Advice[0].Advice | Should -Be 'x advice'
        }
    }
}

Describe 'Gain maintenance' {
    It 'previews, removes old deliveries and clears a history' {
        $config = InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Path=(Join-Path $TestDrive 'clear.sqlite')} { $c=Get-OP2Configuration; $c.DatabasePath=$Path; $c }
        Add-GainDelivery $config -Timestamp '2026-01-01T12:00:00.0000000Z' -SourceBytes 10 -SourceTokens 4 -OutputBytes 1 -OutputTokens 1
        Add-GainDelivery $config -Timestamp '2026-10-01T12:00:00.0000000Z' -SourceBytes 10 -SourceTokens 4 -OutputBytes 1 -OutputTokens 1
        $preview = Clear-OPumper2Measurement -Before ([datetime]'2026-06-01T00:00:00Z') -DatabasePath $config.DatabasePath -WhatIf
        "$($preview.Deliveries)/$($preview.Invocations)/$($preview.Removed)" | Should -BeExactly '1/1/False'
        (Get-OPumper2Gain -DatabasePath $config.DatabasePath -AsObject).Data.Deliveries | Should -Be 2
        $removed = Clear-OPumper2Measurement -Before ([datetime]'2026-06-01T00:00:00Z') -DatabasePath $config.DatabasePath -Confirm:$false
        "$($removed.Database)/$($removed.Deliveries)/$($removed.Invocations)/$($removed.Removed)" | Should -BeExactly "$($config.DatabasePath)/1/1/True"
        (Get-OPumper2Gain -DatabasePath $config.DatabasePath -AsObject).Data.Deliveries | Should -Be 1
        $all = Clear-OPumper2Measurement -All -DatabasePath $config.DatabasePath -Confirm:$false
        "$($all.Deliveries)/$($all.Removed)" | Should -BeExactly '1/True'
        (Get-OPumper2Gain -DatabasePath $config.DatabasePath -AsObject).Data.Deliveries | Should -Be 0
        $absent = Clear-OPumper2Measurement -All -DatabasePath (Join-Path $TestDrive 'never.sqlite') -Confirm:$false
        "$($absent.Deliveries)/$($absent.Invocations)/$($absent.Removed)" | Should -BeExactly '0/0/False'
        Test-Path -LiteralPath (Join-Path $TestDrive 'never.sqlite') | Should -BeFalse
    }
    It 'refreshes the text report until its count, every interval' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $script:WatchCalls = 0
            Mock Get-OPumper2Gain { $script:WatchCalls++; "report $script:WatchCalls" }
            Mock Start-Sleep {}
            $frames = @(Watch-OPumper2Gain -Report @{ GroupBy = 'Command' } -IntervalSeconds 0 -Count 2)
            $frames.Count | Should -Be 2
            $frames[0] | Should -Match "^OPumper2 gain at \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}`nreport 1$"
            $frames[1] | Should -Match "`nreport 2$"
            Should -Invoke Get-OPumper2Gain -Times 2 -Exactly -ParameterFilter { $AsText -and $GroupBy -eq 'Command' }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 0 }
            @(Watch-OPumper2Gain -Count 2).Count | Should -Be 2
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
            $script:WatchCalls = 0
            Mock Get-OPumper2Gain { $script:WatchCalls++; if ($script:WatchCalls -ge 3) { throw 'stop fixture' }; 'report' }
            { Watch-OPumper2Gain -IntervalSeconds 0 } | Should -Throw '*stop fixture*'
            $script:WatchCalls | Should -Be 3
        }
    }
}
