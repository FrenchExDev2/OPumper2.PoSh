BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    function New-TestMeasurementConfiguration {
        # A configuration with its own database, so each test reads only its own history.
        param([string]$Name)
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Path = (Join-Path $TestDrive "$Name.sqlite") } {
            $config = Get-OP2Configuration; $config.DatabasePath = $Path; $config
        }
    }
}

Describe 'Exact measurement contracts' {
    It 'reports an uninitialized empty history without inventing a counter version' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            $saved=$script:OP2Tokenizers.Clone();$path=$script:OP2Environment.OPUMPER2_DB_PATH
            try {
                $script:OP2Tokenizers.Clear();$script:OP2Environment.OPUMPER2_DB_PATH=Join-Path $Directory 'uninitialized.sqlite'
                $result=Get-OPumper2Gain -AsObject
                $result.Data.CounterVersion | Should -BeNullOrEmpty
                $result.Data.Compared | Should -Be 0
                $result.Data.Deliveries | Should -Be 0
                $result.Data.Local.Invocations | Should -Be 0
                $result.Data.Contains('Advice') | Should -BeFalse
                Test-Path -LiteralPath $script:OP2Environment.OPUMPER2_DB_PATH | Should -BeFalse
            } finally {$script:OP2Tokenizers=$saved;$script:OP2Environment.OPUMPER2_DB_PATH=$path}
        }
    }
    It 'counts independent tokenizer fixtures and validates custom counter results' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            Get-OP2TokenCount 'hello world' o200k_base | Should -Be 2
            Get-OP2TokenCount '' o200k_base | Should -Be 0
            Get-OP2TokenCount 'hello world' cl100k_base | Should -Be 2
            foreach($counter in @({-1},{1.5},{'2'},{1;2},{})) {
                Register-OPumper2Tokenizer -Name invalid -Version fixture -Count $counter
                {Get-OP2TokenCount 'text' invalid} | Should -Throw
            }
            {Get-OP2TokenCount 'text' missing} | Should -Throw
            Get-OP2OptionalTokenCount 'hello world' (Get-OP2Configuration) | Should -Be 2
            $broken=Get-OP2Configuration; $broken.Tokenizer='missing'
            Get-OP2OptionalTokenCount 'hello world' $broken | Should -BeNullOrEmpty
        }
        Measure-OPumper2Token 'hello world' | Should -Be 2
        Measure-OPumper2Token '' | Should -Be 0
    }
    It 'loads the configured vocabulary once in the background and never fails the call for it' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $saved=$script:OP2Tokenizers.Clone()
            try {
                $config=Get-OP2Configuration
                $script:OP2Tokenizers.Clear(); $config.Tracking=$false
                Start-OP2TokenizerWarmup $config
                $script:OP2Tokenizers.Count | Should -Be 0
                $config.Tracking=$true
                Start-OP2TokenizerWarmup $config
                $holder=$script:OP2Tokenizers[$config.Tokenizer].Holder
                $pending=$holder.Pending
                $pending | Should -BeOfType ([Threading.Tasks.Task])
                Start-OP2TokenizerWarmup $config
                [object]::ReferenceEquals($holder.Pending,$pending) | Should -BeTrue
                $script:OP2Tokenizers['cl100k_base'].Holder.Pending | Should -BeNullOrEmpty
                Get-OP2TokenCount 'hello world' $config.Tokenizer | Should -Be 2
                [object]::ReferenceEquals($holder.Tokenizer,$pending.Result) | Should -BeTrue
                # A registered counter has no warm step, an unknown name none at all, and a failed initialization is left
                # to the count.
                Register-OPumper2Tokenizer -Name fixture -Version fixture -Count {1}
                foreach($name in @('fixture','missing')) { $config.Tokenizer=$name; { Start-OP2TokenizerWarmup $config } | Should -Not -Throw }
                $script:OP2Tokenizers.Clear()
                Mock Initialize-OP2Dependency { throw 'native dependency' }
                $config.Tokenizer='o200k_base'
                { Start-OP2TokenizerWarmup $config } | Should -Not -Throw
                Should -Invoke Initialize-OP2Dependency -Times 1 -Exactly
            } finally {$script:OP2Tokenizers=$saved}
        }
    }
    It 'counts no tokens for a lossy capture' {
        $config=New-TestMeasurementConfiguration 'lossy'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive;Config=$config} {
            $result=New-OP2Completion -Execution @{ExitCode=0;InvocationIds=@([guid]::NewGuid().ToString('N'));ElapsedMs=0;StdoutBytes=3;StderrBytes=0}
            $result.Capture=@{Stdout="ok$([char]0xFFFD)";Stderr=$null;Complete=$true;Lossy=$true}
            Save-OP2Invocation $result $Directory fixture $Config
            "$($result.Measurement.Status)|$($null -eq $result.Measurement.SourceTokens)|$($result.Measurement.SourceBytes)" | Should -BeExactly 'CounterUnavailable|True|3'
        }
    }
    It 'names the build script when the engine assembly is missing' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Directory = $TestDrive } {
            { Import-OP2EngineAssembly (Join-Path $Directory 'missing.dll') } | Should -Throw '*engine assembly is missing*build/Initialize-Dependencies.ps1*'
            Import-OP2EngineAssembly (Join-Path $script:OP2Root 'resources/runtime/FrenchExDev.OPumper2.Engine.dll')
            [FrenchExDev.OPumper2.Engine.RecordCounter]::new().Sequence | Should -Be 0
        }
    }
    It 'keeps native initialization idempotent and uses a short unpooled SQLite connection' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            Initialize-OP2Dependency
            Initialize-OP2Dependency
            Get-OP2TokenCount 'hello world' o200k_base | Should -Be 2
            $connection=New-OP2Connection (Join-Path $Directory 'connection.sqlite')
            try {
                $connection.DefaultTimeout | Should -Be 1
                $builder=[Microsoft.Data.Sqlite.SqliteConnectionStringBuilder]::new($connection.ConnectionString)
                $builder['Pooling'] | Should -BeFalse
            } finally {$connection.Dispose()}
        }
    }
    It 'measures both complete streams, preserves a leading byte-order mark and records the session' {
        $config=New-TestMeasurementConfiguration 'streams'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive;Config=$config} {
            $previous=$script:OP2Environment['OPUMPER2_SESSION']
            try {
                $script:OP2Environment.OPUMPER2_SESSION='session-a'
                $Config.Tokenizer='characters'
                Register-OPumper2Tokenizer characters fixture {param($text)$text.Length}
                $stdout=Join-Path $Directory 'bom.txt';$stderr=Join-Path $Directory 'stderr.txt'
                [IO.File]::WriteAllText($stdout,([string][char]0xfeff+'é'),[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($stderr,'err')
                $id=[guid]::NewGuid().ToString('N')
                $result=New-OP2Completion -Execution @{ExitCode=0;InvocationIds=@($id);ElapsedMs=0;StdoutBytes=5;StderrBytes=3}
                $result.Capture=@{Stdout=[Text.UTF8Encoding]::new($false).GetString([IO.File]::ReadAllBytes($stdout));Stderr=[IO.File]::ReadAllText($stderr);Complete=$true;Lossy=$false}
                Save-OP2Invocation $result $Directory fixture $Config
                $result.Measurement.SourceBytes | Should -Be 8
                $result.Measurement.SourceTokens | Should -Be 5
                $result.Measurement.Status | Should -Be 'SourceMeasured'
                $row=@(Invoke-OP2Sql $Config 'SELECT label, project, session, outcome, complete FROM invocations WHERE id=@id;' @{id=$id} -Read)[0]
                $row.label | Should -BeExactly 'fixture'
                $row.project | Should -BeExactly (Get-OP2ProjectHash $Directory)
                $row.session | Should -BeExactly 'session-a'
                $row.outcome | Should -Be 'Success'
                $row.complete | Should -Be 1
            } finally {$script:OP2Environment.OPUMPER2_SESSION=$previous}
        }
    }
    It 'never downgrades a newer database schema, and checks a schema once per database and process' {
        $config=New-TestMeasurementConfiguration 'future'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Config=$config} {
            Initialize-OP2Dependency
            # A history a newer engine created before this process first used it.
            $connection=New-OP2Connection $Config.DatabasePath
            try { $connection.Open(); $command=$connection.CreateCommand(); $command.CommandText="PRAGMA user_version=$($script:OP2Migrations.Count + 1);"; [void]$command.ExecuteNonQuery(); $command.Dispose() }
            finally { $connection.Dispose() }
            {Invoke-OP2Sql $Config 'SELECT 1;'} | Should -Throw '*newer*'
            $current=$Config.Clone(); $current.DatabasePath=Join-Path (Split-Path $Config.DatabasePath) 'checked.sqlite'
            Mock Update-OP2Schema {}
            Invoke-OP2Sql $current 'SELECT 1;'
            Invoke-OP2Sql $current 'SELECT 1;'
            Should -Invoke Update-OP2Schema -Times 1 -Exactly
            # A file deleted since is a new history: its schema is created again.
            Remove-Item -LiteralPath $current.DatabasePath
            Invoke-OP2Sql $current 'SELECT 1;'
            Should -Invoke Update-OP2Schema -Times 2 -Exactly
        }
    }
    It 'shares one connection between the writes of a call, never across databases, and drops it on a failure' {
        $config=New-TestMeasurementConfiguration 'shared'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Config=$config} {
            $other=$Config.Clone(); $other.DatabasePath=Join-Path (Split-Path $Config.DatabasePath) 'other.sqlite'
            $scope = Enter-OP2Call 1
            $path = [IO.Path]::GetFullPath($Config.DatabasePath)
            $otherPath = [IO.Path]::GetFullPath($other.DatabasePath)
            try {
                Invoke-OP2Sql $Config 'SELECT 1;'
                $first=$scope.Account.Stores[$path].Connection
                @(Invoke-OP2Sql $Config 'SELECT 2 AS Two;' -Read)[0].Two | Should -Be 2
                [object]::ReferenceEquals($first, $scope.Account.Stores[$path].Connection) | Should -BeTrue
                $first.State | Should -Be 'Open'
                # Another database gets its own connection and leaves the shared one alone.
                Invoke-OP2Sql $other 'SELECT 1;'
                [object]::ReferenceEquals($first, $scope.Account.Stores[$path].Connection) | Should -BeTrue
                $otherConnection = $scope.Account.Stores[$otherPath].Connection
                $scope.Account.Stores.Count | Should -Be 2
                # A transaction a failure left open goes with the connection.
                {Invoke-OP2Sql $Config 'BEGIN; CREATE TABLE kept(x); SELECT * FROM missing;'} | Should -Throw '*missing*'
                $scope.Account.Stores.ContainsKey($path) | Should -BeFalse
                $otherConnection.State | Should -Be 'Open'
                @(Invoke-OP2Sql $Config "SELECT COUNT(*) AS Count FROM sqlite_master WHERE name='kept';" -Read)[0].Count | Should -Be 0
                $failedRead=$scope.Account.Stores[$path].Connection
                {@(Invoke-OP2Sql $Config 'SELECT * FROM missing;' -Read)} | Should -Throw '*missing*'
                $failedRead.State | Should -Be 'Closed'
            } finally { Exit-OP2Call $scope }
            # The outermost call closes it.
            $scope.Account.Stores.Count | Should -Be 0
            $otherConnection.State | Should -Be 'Closed'
            $first.State | Should -Be 'Closed'
        }
    }
    It 'migrates earlier histories in place, keeps their rows and rolls a failing migration back' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            Initialize-OP2Dependency
            function New-Schema([string]$Name, [int]$Version, [string]$Extra='') {
                $path=Join-Path $Directory "$Name.sqlite"
                $connection=New-OP2Connection $path
                try {
                    $connection.Open(); $command=$connection.CreateCommand()
                    $command.CommandText=(@($script:OP2Migrations | Select-Object -First $Version) -join "`n") + $Extra +
                        "INSERT INTO deliveries(id,timestamp,bytes,tokens,profile,version) VALUES('old','2026-01-01T00:00:00Z',1,1,'p','v'); PRAGMA user_version=$Version;"
                    [void]$command.ExecuteNonQuery(); $command.Dispose()
                } finally { $connection.Dispose() }
                $config=Get-OP2Configuration; $config.DatabasePath=$path; $config
            }
            foreach ($version in @(1,2)) {
                $config=New-Schema "schema$version" $version
                $row=@(Invoke-OP2Sql $config 'SELECT id, route, provider, format FROM deliveries;' -Read)[0]
                $row.id | Should -Be 'old'
                $row.route | Should -BeNullOrEmpty
                $row.format | Should -BeNullOrEmpty
                @(Invoke-OP2Sql $config 'PRAGMA user_version;' -Read)[0].user_version | Should -Be $script:OP2Migrations.Count
                @(Invoke-OP2Sql $config "SELECT length(value) AS Length FROM settings WHERE key='salt';" -Read)[0].Length | Should -Be 64
                # Local volume and recall joins look links up by invocation, which the primary key cannot serve.
                @(Invoke-OP2Sql $config "SELECT name FROM sqlite_master WHERE type='index' AND name='delivery_invocations_invocation';" -Read).Count | Should -Be 1
                Invoke-OP2Sql $config 'SELECT 1;'
                @(Invoke-OP2Sql $config 'SELECT COUNT(*) AS Count FROM deliveries;' -Read)[0].Count | Should -Be 1
            }
            $broken=New-Schema 'broken' 1 'ALTER TABLE deliveries ADD COLUMN route TEXT;'
            {Invoke-OP2Sql $broken 'SELECT 1;'} | Should -Throw '*duplicate column*'
            $connection=New-OP2Connection $broken.DatabasePath
            try { $connection.Open(); $command=$connection.CreateCommand(); $command.CommandText='PRAGMA user_version;'; $command.ExecuteScalar() | Should -Be 1 }
            finally { $connection.Dispose() }
        }
    }
    It 'records a delivery with its context, composition and alternate format, and isolates tokenizer versions' {
        $config=New-TestMeasurementConfiguration 'delivery'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive;Config=$config} {
            $previous=$script:OP2Environment['OPUMPER2_SESSION']
            try {
                $script:OP2Environment.OPUMPER2_SESSION='session-b'
                $source=Join-Path $Directory 'source.txt';[IO.File]::WriteAllText($source,'hello world')
                $id=[guid]::NewGuid().ToString('N')
                $result=New-OP2Completion -Outcome Failed -Execution @{ExitCode=1;InvocationIds=@($id,$id);ElapsedMs=1;StdoutBytes=11;StderrBytes=0}
                $result.Capture=@{Stdout=[IO.File]::ReadAllText($source);Stderr=$null;Complete=$true;Lossy=$false}; Save-OP2Invocation $result $Directory fixture $Config
                $result.Measurement.SourceBytes | Should -Be 11
                $result.Measurement.SourceTokens | Should -Be 2
                $parts=@{Data='hello world';Records='hello';Excerpt='';AlternateFormat='json';Alternate='[{"a":1}]'}
                Save-OP2Delivery $result '[{}]' $Config -Origin @{Route='fixture.route';Provider='fixture';Command="tool`0arg"} -Format yaml -Parts $parts -Truncation 'ItemLimit,DataLimit'
                $result.Measurement.OutputBytes | Should -Be 4
                $result.Measurement.OutputTokens | Should -BeGreaterThan 0
                $result.Measurement.Status | Should -Be 'Delivered'
                $row=@(Invoke-OP2Sql $Config 'SELECT * FROM deliveries;' -Read)[0]
                $row.route | Should -BeExactly 'fixture.route'
                $row.provider | Should -BeExactly 'fixture'
                $row.format | Should -BeExactly 'yaml'
                $row.outcome | Should -BeExactly 'Failed'
                $row.truncation | Should -BeExactly 'ItemLimit,DataLimit'
                $row.session | Should -BeExactly 'session-b'
                $row.fingerprint | Should -BeExactly (Get-OP2Fingerprint "tool`0arg" $Config)
                $row.fingerprint | Should -Match '^[0-9A-F]{64}$'
                $row.data_tokens | Should -Be 2
                $row.record_tokens | Should -Be 1
                $row.excerpt_tokens | Should -Be 0
                $row.alternate_format | Should -BeExactly 'json'
                $row.alternate_bytes | Should -Be 9
                $row.alternate_tokens | Should -BeGreaterThan 0
                @(Invoke-OP2Sql $Config 'SELECT COUNT(*) AS Count FROM delivery_invocations;' -Read)[0].Count | Should -Be 1
                $other=Get-OP2Configuration; $other.DatabasePath=Join-Path $Directory 'other-salt.sqlite'
                Get-OP2Fingerprint "tool`0arg" $other | Should -Not -Be $row.fingerprint
                Save-OP2Delivery $result '[]' $Config
                $plain=@(Invoke-OP2Sql $Config 'SELECT route, fingerprint, truncation, data_tokens, alternate_format, alternate_bytes FROM deliveries ORDER BY timestamp DESC LIMIT 1;' -Read)[0]
                $plain.route | Should -BeNullOrEmpty
                $plain.fingerprint | Should -BeNullOrEmpty
                $plain.truncation | Should -BeNullOrEmpty
                $plain.data_tokens | Should -Be 0
                $plain.alternate_format | Should -BeNullOrEmpty
                $plain.alternate_bytes | Should -BeNullOrEmpty
                $gain=Get-OPumper2Gain -DatabasePath $Config.DatabasePath -AsObject
                $gain.Data.Profile | Should -Be 'o200k_base'
                $gain.Data.CounterVersion | Should -Be 'Microsoft.ML.Tokenizers/2.0.0'
                $gain.Data.Deliveries | Should -Be 2
                Register-OPumper2Tokenizer o200k_base new-version {1}
                $changed=Get-OPumper2Gain -DatabasePath $Config.DatabasePath -AsObject
                $changed.Data.Compared | Should -Be 0
                $changed.Data.SavedTokens | Should -BeNullOrEmpty
                $script:OP2Tokenizers.Remove('o200k_base');Initialize-OP2Dependency
            } finally {$script:OP2Environment.OPUMPER2_SESSION=$previous}
        }
    }
    It 'applies the retention with each delivery and keeps what a retained delivery needs' {
        $config=New-TestMeasurementConfiguration 'retention'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Config=$config} {
            Initialize-OP2Dependency
            $version=$script:OP2Tokenizers[$Config.Tokenizer].Version
            $old=[DateTime]::UtcNow.AddDays(-10).ToString('O'); $recent=[DateTime]::UtcNow.AddHours(-2).ToString('O')
            foreach ($row in @(@('old-delivery','old-call',$old,$old),@('kept-delivery','spanning-call',$recent,$old),@($null,'old-local',$null,$old),@($null,'recent-local',$null,$recent))) {
                Invoke-OP2Sql $Config "INSERT INTO invocations(id,timestamp,label,project,outcome,bytes,tokens,profile,version,complete,elapsed) VALUES(@call,@callTime,'x','p','Success',1,1,@profile,@version,1,1);" @{call=$row[1];callTime=$row[3];profile=$Config.Tokenizer;version=$version}
                if ($row[0]) {
                    Invoke-OP2Sql $Config "INSERT INTO deliveries(id,timestamp,bytes,tokens,profile,version) VALUES(@id,@time,1,1,@profile,@version); INSERT INTO delivery_invocations VALUES(@id,@call);" @{id=$row[0];call=$row[1];time=$row[2];profile=$Config.Tokenizer;version=$version}
                }
            }
            $Config.RetentionDays=0
            Save-OP2Delivery (New-OP2Completion) '[]' $Config
            @(Invoke-OP2Sql $Config 'SELECT COUNT(*) AS Count FROM deliveries;' -Read)[0].Count | Should -Be 3
            $Config.RetentionDays=1
            $current=New-OP2Completion
            Save-OP2Delivery $current '[]' $Config
            $current.Measurement.Status | Should -Be 'Delivered'
            (@(Invoke-OP2Sql $Config 'SELECT id FROM deliveries WHERE id IN (''old-delivery'',''kept-delivery'') ORDER BY id;' -Read) | ForEach-Object id) -join ',' | Should -Be 'kept-delivery'
            @(Invoke-OP2Sql $Config 'SELECT COUNT(*) AS Count FROM deliveries;' -Read)[0].Count | Should -Be 3
            (@(Invoke-OP2Sql $Config 'SELECT id FROM invocations ORDER BY id;' -Read) | ForEach-Object id) -join ',' | Should -Be 'recent-local,spanning-call'
        }
    }
    It 'stores nothing when tracking is off' {
        $config=New-TestMeasurementConfiguration 'untracked'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive;Config=$config} {
            $Config.Tracking=$false
            $source=Join-Path $Directory 'untracked.txt';[IO.File]::WriteAllText($source,'hello')
            $result=New-OP2Completion -Execution @{ExitCode=0;InvocationIds=@([guid]::NewGuid().ToString('N'));ElapsedMs=0;StdoutBytes=5;StderrBytes=0}
            $result.Capture=@{Stdout=[IO.File]::ReadAllText($source);Stderr=$null;Complete=$true;Lossy=$false}; Save-OP2Invocation $result $Directory fixture $Config
            $result.Measurement.Status | Should -Be 'TrackingDisabled'
            $result.Measurement.SourceTokens | Should -BeNullOrEmpty
            $result.Measurement.Status='SourceMeasured'
            Save-OP2Delivery $result '[]' $Config
            $result.Measurement.Status | Should -Be 'TrackingDisabled'
            Test-Path -LiteralPath $Config.DatabasePath | Should -BeFalse
        }
    }
    It 'reports failures without changing the business result' {
        $config=New-TestMeasurementConfiguration 'failures'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive;Config=$config} {
            $source=Join-Path $Directory 'broken-count.txt';[IO.File]::WriteAllText($source,'hello')
            $result=New-OP2Completion -Execution @{ExitCode=0;InvocationIds=@([guid]::NewGuid().ToString('N'));ElapsedMs=0;StdoutBytes=5;StderrBytes=0}
            Register-OPumper2Tokenizer broken fixture {throw 'fixture'}
            $Config.Tokenizer='broken'
            $result.Capture=@{Stdout=[IO.File]::ReadAllText($source);Stderr=$null;Complete=$true;Lossy=$false}; Save-OP2Invocation $result $Directory fixture $Config
            $result.Measurement.Status | Should -Be 'CounterUnavailable'
            $result.Outcome | Should -Be 'Success'
            Save-OP2Delivery $result '[]' $Config -Parts @{Data='x'}
            $result.Measurement.Status | Should -Be 'DeliveredWithoutTokens'
            @(Invoke-OP2Sql $Config 'SELECT data_tokens FROM deliveries;' -Read)[0].data_tokens | Should -BeNullOrEmpty
            $row=@(Invoke-OP2Sql $Config 'SELECT @value AS Value' @{value=$null} -Read)[0]
            $row.Value | Should -BeNullOrEmpty
            $Config.DatabasePath=Join-Path $Directory 'bad-db'
            [void][IO.Directory]::CreateDirectory($Config.DatabasePath)
            $result.Capture=@{Stdout=[IO.File]::ReadAllText($source);Stderr=$null;Complete=$true;Lossy=$false}; Save-OP2Invocation $result $Directory fixture $Config
            $result.Measurement.Status | Should -Be 'StorageUnavailable'
            Save-OP2Delivery $result '[]' $Config
            $result.Measurement.Status | Should -Be 'DeliveryUnavailable'
            $result.Outcome | Should -Be 'Success'
        }
    }
    It 'rejects an unknown configured tokenizer when reading history' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            $config=Get-OP2Configuration
            Invoke-OP2Sql $config 'SELECT 1;'
            $path=Join-Path $Directory 'unknown-tokenizer.yaml'
            [IO.File]::WriteAllText($path,"general:`n  tokenizer: unknown-fixture")
            $previous=$script:OP2Environment.OPUMPER2_CONFIG_PATH
            try {
                $script:OP2Environment.OPUMPER2_CONFIG_PATH=$path
                (Get-OPumper2Gain -AsObject).Outcome | Should -Be 'Failed'
                Get-OPumper2Gain -AsText | Should -Match '^OPumper2 gain unavailable: Unknown tokenizer\.$'
            } finally {$script:OP2Environment.OPUMPER2_CONFIG_PATH=$previous}
        }
    }
}
