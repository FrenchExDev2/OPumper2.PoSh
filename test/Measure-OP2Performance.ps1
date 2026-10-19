#requires -Version 7.6
# End-to-end performance baseline. Each scenario runs in a fresh pwsh process, as an agent tool call does, with its own
# measurement database and no configuration file; the steps time themselves and print one JSON line. Compare runs of
# the same machine before and after a change; absolute values depend on the host.
[CmdletBinding()]
param([ValidateSet('Routed','Lines','BigData','Gain')][string[]]$Scenario = @('Routed','Lines','BigData','Gain'),
    [ValidateRange(1,1000000)][int]$Lines = 20000, [ValidateRange(1,1000000)][int]$GainRows = 20000,
    # Files of the routed scenario's repository: half committed, then one in two of those modified; the other half
    # untracked. Zero keeps an empty repository.
    [ValidateRange(0,1000000)][int]$Paths = 0)
$ErrorActionPreference = 'Stop'
$engine = Split-Path $PSScriptRoot
$parent = Split-Path $engine
. (Join-Path $PSScriptRoot 'ToolSupport.ps1')
Import-Module (Join-Path $engine 'FrenchExDev.OPumper2.PoSh.psd1') -DisableNameChecking
$executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$work = Join-Path ([IO.Path]::GetTempPath()) ('opumper2-perf-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
# The launcher's own child runs stay out of the user's measurement history; each scenario sets its own database.
$tracking = $env:OPUMPER2_TRACKING
$env:OPUMPER2_TRACKING = '0'

function ConvertTo-PerfLiteral {
    param([string]$Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

# The native output of the line scenarios: MSBuild-like lines, 1 % errors and 1 % warnings, the rest ordinary.
function Write-PerfOutput {
    param([string]$Path, [int]$Count)
    $builder = [Text.StringBuilder]::new()
    for ($index = 1; $index -le $Count; $index++) {
        $project = "P$($index % 7)"
        if ($index % 100 -eq 0) { [void]$builder.Append("C:\src\$project\F$index.cs(10,5): error CS$('{0:0000}' -f ($index % 40)): The name 'Thing$index' does not exist in the current context [C:\src\$project\$project.csproj::TargetFramework=net10.0]`n") }
        elseif ($index % 50 -eq 0) { [void]$builder.Append("C:\src\$project\F$index.cs(12,9): warning CA$('{0:0000}' -f (1000 + $index % 40)): Consider doing something about member $index [C:\src\$project\$project.csproj::TargetFramework=net10.0]`n") }
        else { [void]$builder.Append("  Determining projects to restore for item $index... $project -> C:\src\bin\$project.dll`n") }
    }
    [IO.File]::WriteAllText($Path, $builder.ToString(), [Text.UTF8Encoding]::new($false))
}

function Invoke-PerfScenario {
    param([string]$Name, [string]$Body, [string]$Database)
    $prelude = @"
`$age = ((Get-Date) - (Get-Process -Id `$PID).StartTime).TotalMilliseconds
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false)
`$ErrorActionPreference = 'Stop'
`$env:OPUMPER2_DB_PATH = $(ConvertTo-PerfLiteral $Database)
`$env:OPUMPER2_CONFIG_PATH = $(ConvertTo-PerfLiteral (Join-Path $work 'absent.yaml'))
`$env:OPUMPER2_TRACKING = `$null
`$m =[ordered]@{ Scenario = '$Name'; ProcessStartMs = [Math]::Round(`$age) }
function Step([string]`$Name, [scriptblock]`$Body) { `$w = [Diagnostics.Stopwatch]::StartNew(); `$value = & `$Body; `$m[`$Name] = [Math]::Round(`$w.Elapsed.TotalMilliseconds, 1); `$value }
Step ImportEngineMs { Import-Module $(ConvertTo-PerfLiteral (Join-Path $engine 'FrenchExDev.OPumper2.PoSh.psd1')) -DisableNameChecking -Global } | Out-Null
"@
    $epilogue = "`n[Console]::Out.WriteLine((`$m | ConvertTo-Json -Compress -Depth 4))"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-OP2TestTool -FilePath $executable -ArgumentList @('-NoProfile','-NonInteractive','-Command',($prelude + "`n" + $Body + $epilogue))
    $line = @($run.Stdout -split "`r?`n" | Where-Object { $_.StartsWith('{') })[-1]
    if ($run.Outcome -ne 'Success' -or !$line) {
        return [ordered]@{ Scenario = $Name; Outcome = 'Failed'; ExitCode = $run.ExitCode; Error = @($run.Stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 5) }
    }
    $result = $line | ConvertFrom-Json -AsHashtable
    $result.WallMs = [Math]::Round($watch.Elapsed.TotalMilliseconds)
    $result.Outcome = 'Success'
    return $result
}

try {
    $results = [Collections.Generic.List[object]]::new()
    $module = { param($name) ConvertTo-PerfLiteral (Join-Path $parent "$name/$name.psd1") }
    $generator = { param($path) ConvertTo-PerfLiteral "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false); [Console]::Out.Write([IO.File]::ReadAllText('$($path.Replace("'", "''"))'))" }
    if ('Routed' -in $Scenario) {
        $repository = Join-Path $work 'repository'
        [void][IO.Directory]::CreateDirectory($repository)
        $init = Invoke-OP2TestTool -FilePath git -ArgumentList @('init','-q',$repository)
        if ($init.Outcome -ne 'Success') { throw 'git init failed for the routed scenario.' }
        if ($Paths) {
            $committed = [int][Math]::Floor($Paths / 2)
            for ($index = 0; $index -lt $Paths; $index++) {
                $folder = Join-Path $repository "src/d$([Math]::Floor($index / 100))"
                if ($index % 100 -eq 0) { [void][IO.Directory]::CreateDirectory($folder) }
                [IO.File]::WriteAllText((Join-Path $folder "f$index.txt"), "file $index`n")
                # The committed half is staged as it is written; the rest stays untracked.
                if ($index -eq $committed - 1) {
                    $add = Invoke-OP2TestTool -FilePath git -ArgumentList @('-C', $repository, 'add', '--all') -TimeoutSeconds 1800
                    $commit = Invoke-OP2TestTool -FilePath git -ArgumentList @('-C', $repository, '-c', 'user.name=perf', '-c', 'user.email=perf@localhost', 'commit', '-q', '-m', 'perf') -TimeoutSeconds 1800
                    if ($add.Outcome -ne 'Success' -or $commit.Outcome -ne 'Success') { throw 'Could not commit the routed scenario files.' }
                }
            }
            for ($index = 0; $index -lt $committed; $index += 2) {
                [IO.File]::AppendAllText((Join-Path $repository "src/d$([Math]::Floor($index / 100))/f$index.txt"), "changed`n")
            }
        }
        $results.Add((Invoke-PerfScenario 'Routed' @"
`$m.Paths = $Paths
Step ImportAgentMs { Import-Module $(& $module 'FrenchExDev.OPumper2.Utility.Agent.PoSh') -Global } | Out-Null
Step ImportWorkspaceMs { Import-OPumper2Workspace } | Out-Null
`$text = Step PumpFirstMs { pump -WorkingDirectory $(ConvertTo-PerfLiteral $repository) git status }
`$m.DeliveredBytes = [Text.Encoding]::UTF8.GetByteCount([string]`$text)
Step PumpSecondMs { pump -WorkingDirectory $(ConvertTo-PerfLiteral $repository) git status } | Out-Null
"@ (Join-Path $work 'routed.sqlite')))
    }
    if ('Lines' -in $Scenario) {
        $output = Join-Path $work 'lines.txt'
        Write-PerfOutput $output $Lines
        $results.Add((Invoke-PerfScenario 'Lines' @"
`$exe = $(ConvertTo-PerfLiteral $executable)
`$gen = @('-NoProfile','-NonInteractive','-Command',$(& $generator $output))
`$m.Lines = $Lines
Step GeneratorRawMs { `$info = [Diagnostics.ProcessStartInfo]::new(`$exe); foreach (`$a in `$gen) { `$info.ArgumentList.Add(`$a) }; `$info.RedirectStandardOutput = `$true; `$info.UseShellExecute = `$false; `$p = [Diagnostics.Process]::Start(`$info); [void]`$p.StandardOutput.ReadToEnd(); `$p.WaitForExit(); `$p.Dispose() } | Out-Null
`$text = Step PumpFirstMs { Pump-Me `$exe -ArgumentList `$gen -OnRecord { param(`$r, `$s) } }
Step PumpSecondMs { Pump-Me `$exe -ArgumentList `$gen -OnRecord { param(`$r, `$s) } } | Out-Null
`$env:OPUMPER2_TRACKING = '0'
Step PumpUntrackedMs { Pump-Me `$exe -ArgumentList `$gen -OnRecord { param(`$r, `$s) } } | Out-Null
Remove-Item Env:OPUMPER2_TRACKING
`$id = ([regex]::Match([string]`$text, 'Recall: (\w+)')).Groups[1].Value
`$m.RecallStored = [bool]`$id
Step RecallGrepMs { Get-OPumper2Recall `$id -Grep 'error CS' } | Out-Null
Step RecallReplayMs { Invoke-OPumper2Recall `$id -OnRecord { param(`$r, `$s) } } | Out-Null
Step ImportDotnetMs { Import-Module $(& $module 'FrenchExDev.OPumper2.Dotnet.PoSh') -Global } | Out-Null
Step ShadowDotnetMs { Measure-OPumper2Contract -Contract { New-DotnetBuildContract -WorkingDirectory 'C:\src' } -Recall `$id -AsJson } | Out-Null
"@ (Join-Path $work 'lines.sqlite')))
    }
    if ('BigData' -in $Scenario) {
        $results.Add((Invoke-PerfScenario 'BigData' @"
`$exe = $(ConvertTo-PerfLiteral $executable)
`$items = { param(`$s, `$e) foreach (`$i in 1..5000) { [pscustomobject]@{ File = "f`$i.cs"; Line = `$i; Message = 'warning text here' } } }
Step PumpYamlMs { Pump-Me `$exe -ArgumentList @('-NoProfile','-NonInteractive','-Command','1') -OnRecord { param(`$r, `$s) } -Complete `$items } | Out-Null
Step PumpJsonMs { Pump-Me `$exe -ArgumentList @('-NoProfile','-NonInteractive','-Command','1') -OnRecord { param(`$r, `$s) } -Complete `$items -AsJson } | Out-Null
"@ (Join-Path $work 'bigdata.sqlite')))
    }
    if ('Gain' -in $Scenario) {
        $results.Add((Invoke-PerfScenario 'Gain' @"
`$m.Rows = $GainRows
Step SeedMs { & (Get-Module FrenchExDev.OPumper2.PoSh) {
    param(`$count)
    `$configuration = Get-OP2Configuration
    [void]@(Invoke-OP2Sql -Configuration `$configuration -Read -Sql 'SELECT 1 AS one;')
    `$version = `$script:OP2Tokenizers[`$configuration.Tokenizer].Version
    `$connection = New-OP2Connection ([IO.Path]::GetFullPath(`$configuration.DatabasePath)); `$connection.Open()
    `$transaction = `$connection.BeginTransaction()
    `$command = `$connection.CreateCommand(); `$command.Transaction = `$transaction
    `$command.CommandText = "INSERT INTO invocations(id,timestamp,label,project,outcome,bytes,tokens,profile,version,complete,elapsed,session) VALUES(@i,@t,'git','p','Success',5000,1200,@p,@v,1,40.0,'s'); INSERT INTO deliveries(id,timestamp,bytes,tokens,profile,version,route,provider,format,outcome,session,fingerprint,data_tokens,record_tokens,excerpt_tokens) VALUES(@d,@t,500,120,@p,@v,@r,'local','yaml','Success','s',@f,60,0,0); INSERT INTO delivery_invocations VALUES(@d,@i);"
    foreach (`$name in 'i','t','p','v','d','r','f') { [void]`$command.Parameters.Add([Microsoft.Data.Sqlite.SqliteParameter]::new("@`$name", [DBNull]::Value)) }
    `$command.Parameters['@p'].Value = `$configuration.Tokenizer; `$command.Parameters['@v'].Value = `$version
    `$start = [DateTimeOffset]::UtcNow.AddMinutes(-`$count)
    for (`$index = 0; `$index -lt `$count; `$index++) {
        `$command.Parameters['@i'].Value = [guid]::NewGuid().ToString('N'); `$command.Parameters['@d'].Value = [guid]::NewGuid().ToString('N')
        `$command.Parameters['@t'].Value = `$start.AddMinutes(`$index).UtcDateTime.ToString('O')
        `$command.Parameters['@r'].Value = `$(if (`$index % 3) { 'git.status' } else { [DBNull]::Value })
        `$command.Parameters['@f'].Value = "fp`$(`$index % 500)"
        [void]`$command.ExecuteNonQuery()
    }
    `$transaction.Commit(); `$command.Dispose(); `$connection.Dispose()
} $GainRows } | Out-Null
Step GainTextMs { Get-OPumper2Gain -GroupBy Command -AsText } | Out-Null
"@ (Join-Path $work 'gain.sqlite')))
    }
    $results | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 }
} finally {
    $env:OPUMPER2_TRACKING = $tracking
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
