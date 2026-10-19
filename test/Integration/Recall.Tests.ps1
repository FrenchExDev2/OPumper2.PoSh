BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    $script:Previous = @{ OPUMPER2_DB_PATH = (Set-TestEnvironment OPUMPER2_DB_PATH (Join-Path $TestDrive 'recall.sqlite')) }
    $script:Label = [IO.Path]::GetFileName($script:OP2TestExecutable)
    function Invoke-Listing([int]$Lines, [int]$Code) {
        $script = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false); 1..$Lines | ForEach-Object { 'item ' + `$_ }; [Console]::Error.WriteLine('fatal: listing failed'); exit $Code"
        pump -OnRecord {} -AsJson $script:OP2TestExecutable -NoProfile -NonInteractive -Command $script
    }
}
AfterAll { foreach ($name in $script:Previous.Keys) { Set-TestEnvironment $name $script:Previous[$name] | Out-Null } }

Describe 'Recalled outputs of real calls' {
    It 'names the stored output in the delivery and reads it back instead of running again' {
        $delivered = (Invoke-Listing 400 3 | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
        $delivered.Recall | Should -Match '^[0-9a-f]{12}$'
        $read = (Get-OPumper2Recall $delivered.Recall -Grep '^item 39\d$' -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
        $read.Data.Matched | Should -Be 10
        $read.Data.Command | Should -BeExactly $script:Label
        $read.Data.ExitCode | Should -Be 3
        $gain = (Get-OPumper2Gain -AsObject).Data
        "$($gain.Stored)|$($gain.Recalled)|$($gain.RecallRate)" | Should -BeExactly '1|1|1'
        $previous = Set-TestEnvironment OPUMPER2_RECALL '0'
        try { (Invoke-Listing 10 0 | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].ContainsKey('Recall') | Should -BeFalse }
        finally { Set-TestEnvironment OPUMPER2_RECALL $previous | Out-Null }
    }
    It 'measures a candidate contract against what the recalled outputs delivered' {
        Invoke-Listing 300 0 | Out-Null
        $contract = { [pscustomobject]@{ State = @{ Items = 0 }; OnRecord = { param($r, $s) if ($r.Text -like 'item *') { $s.Items++ } }; Complete = { param($s) $s.Items } } }
        $shadow = (Measure-OPumper2Contract -Contract $contract -AsObject).Data
        "$($shadow.Outputs)|$($shadow.Compared)" | Should -BeExactly '2|2'
        $shadow.ShadowTokens | Should -BeLessThan $shadow.DeliveredTokens
        $shadow.SavedVsDelivered | Should -Be ($shadow.DeliveredTokens - $shadow.ShadowTokens)
        $shadow.ShadowRate | Should -BeGreaterThan 0.9
        (Measure-OPumper2Contract -Contract $contract -Recall $shadow.Entries[0].Recall -AsObject).Data.Outputs | Should -Be 1
        (Measure-OPumper2Contract -Contract $contract -Command $script:Label -Format json -AsObject).Data.Outputs | Should -Be 2
        (Measure-OPumper2Contract -Contract $contract -Command 'other' -AsObject).Data.Outputs | Should -Be 0
        (Measure-OPumper2Contract -Contract $contract -Since ([datetime]::UtcNow.AddDays(1)) -AsObject).Data.ShadowRate | Should -BeNullOrEmpty
        $projected = { [pscustomobject]@{ State = @{}; OnRecord = {}; Complete = { param($s) 'full' }; Projection = { param($d) 'short' } } }
        (Measure-OPumper2Contract -Contract $projected -AsObject).Data.Entries[0].ShadowTokens | Should -BeGreaterThan 0
        Measure-OPumper2Contract -Contract $contract -AsText | Should -Match '^Shadow contract over 2 of 2 recalled outputs: '
        (Measure-OPumper2Contract -Contract $contract -AsJson | ConvertFrom-Json)[0].Data.Compared | Should -Be 2
        Measure-OPumper2Contract -Contract $contract -AsYaml | Should -Match 'Compared: 2'
        # Totals are the sums over compared outputs; the rate is relative to the captured tokens.
        $sum = { param($name) [long](@($shadow.Entries | ForEach-Object { $_.$name }) | Measure-Object -Sum).Sum }
        "$($shadow.SourceTokens)|$($shadow.DeliveredTokens)|$($shadow.ShadowTokens)" | Should -BeExactly "$(& $sum SourceTokens)|$(& $sum DeliveredTokens)|$(& $sum ShadowTokens)"
        $shadow.ShadowRate | Should -Be (($shadow.SourceTokens - $shadow.ShadowTokens) / $shadow.SourceTokens)
        foreach ($entry in $shadow.Entries) { $entry.Difference | Should -Be ($entry.DeliveredTokens - $entry.ShadowTokens) }
        $database = Join-Path $TestDrive 'recall.sqlite'
        (Measure-OPumper2Contract -Contract $contract -DatabasePath $database -AsObject).Data.Outputs | Should -Be 2
        # Without -Format, the configured delivery format decides.
        $jsonConfig = Join-Path $TestDrive 'shadow-json.yaml'
        [IO.File]::WriteAllText($jsonConfig, "general:`n  outputFormat: json`n  timeoutSeconds: 60")
        $json = (Measure-OPumper2Contract -Contract $contract -Format json -AsObject).Data.ShadowTokens
        $previous = Set-TestEnvironment OPUMPER2_CONFIG_PATH $jsonConfig
        try { (Measure-OPumper2Contract -Contract $contract -AsObject).Data.ShadowTokens | Should -Be $json }
        finally { Set-TestEnvironment OPUMPER2_CONFIG_PATH $previous | Out-Null }
        $shadow.ShadowTokens | Should -Not -Be $json
        # An output whose delivered or captured tokens are unknown is listed but not compared.
        $first = $shadow.Entries[0].Recall; $second = $shadow.Entries[1].Recall
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Path = $database; First = $first; Second = $second } {
            $c = Get-OP2Configuration; $c.DatabasePath = $Path
            Invoke-OP2Sql $c 'UPDATE deliveries SET tokens=NULL WHERE id IN (SELECT x.delivery FROM delivery_invocations x JOIN recalls r ON r.invocation=x.invocation WHERE r.id=@id);' @{ id = $First }
            Invoke-OP2Sql $c 'UPDATE invocations SET tokens=NULL WHERE id=(SELECT invocation FROM recalls WHERE id=@id);' @{ id = $Second }
        }
        $unknown = (Measure-OPumper2Contract -Contract $contract -AsObject).Data
        "$($unknown.Outputs)|$($unknown.Compared)|$($unknown.SourceTokens)|$($unknown.ShadowRate)" | Should -BeExactly '2|0|0|'
        $unknown.Entries[0].Difference | Should -BeNullOrEmpty
        $unknown.Entries[1].Difference | Should -Not -BeNullOrEmpty
    }
    It 'runs a bypassed command as is and measures it as delivered in full' {
        # Writers substituted in this runspace only: the process console is shared with concurrent test runspaces.
        $writers = @{ stdout = [IO.StringWriter]::new(); stderr = [IO.StringWriter]::new() }
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Writers = $writers } { $script:OP2BypassWriter = $Writers }
        try {
            Invoke-OPumper2Bypass $script:OP2TestExecutable -ArgumentList @('-NoProfile','-NonInteractive','-Command',"'raw line'; [Console]::Error.WriteLine('raw error'); exit 4")
            $exitCode = $LASTEXITCODE
            # The documented form: the command, then its arguments, all positional (quoted so PowerShell keeps the dashes).
            Invoke-OPumper2Bypass $script:OP2TestExecutable '-NoProfile' '-NonInteractive' '-Command' "'positional line'"
        } finally { InModuleScope FrenchExDev.OPumper2.PoSh { $script:OP2BypassWriter = $null } }
        "$($writers.stdout.ToString().Trim() -replace '\r?\n', '|')/$($writers.stderr.ToString().Trim())/$exitCode/$LASTEXITCODE" | Should -BeExactly 'raw line|positional line/raw error/4/0'
        $bypass = (Get-OPumper2Gain -GroupBy Route -AsObject).Data.Groups | Where-Object Key -EQ 'bypass'
        "$($bypass.Compared)|$($bypass.SavedBytes)" | Should -BeExactly '2|0'
        ((Get-OPumper2Gain -GroupBy Format -AsObject).Data.Groups | Where-Object Key -EQ 'raw').Compared | Should -Be 2
        InModuleScope FrenchExDev.OPumper2.PoSh {
            [object]::ReferenceEquals((Get-OP2BypassWriter 'stdout'), [Console]::Out) | Should -BeTrue
            [object]::ReferenceEquals((Get-OP2BypassWriter 'stderr'), [Console]::Error) | Should -BeTrue
        }
    }
}
