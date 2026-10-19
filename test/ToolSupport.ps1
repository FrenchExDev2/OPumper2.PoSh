function Get-OP2TestPackage {
    # Validated packages: launcher name to folder; each folder holds <folder>.psd1/.psm1 and test, and src when it has
    # code beyond its loader. Catalogue packages hold filters data and a loader only.
    $packages = [ordered]@{ Engine = 'FrenchExDev.OPumper2.PoSh'; Git = 'FrenchExDev.OPumper2.Git.PoSh'; Dotnet = 'FrenchExDev.OPumper2.Dotnet.PoSh' }
    foreach ($name in @(Get-OP2CataloguePackage)) { $packages[$name] = "FrenchExDev.OPumper2.$name.PoSh" }
    $packages.Agent = 'FrenchExDev.OPumper2.Utility.Agent.PoSh'
    return $packages
}

function Get-OP2CataloguePackage {
    # Ecosystem catalogue packages, read by the engine's filter interpreter.
    @('Node','Python','Rust','Go','Make','Jvm','Containers','Kubernetes','Systemd','GitHub','Terraform','Search')
}

function Invoke-OP2TestTool {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory = (Get-Location).Path, [int]$TimeoutSeconds = 600)
    $state = @{ Stdout = [Text.StringBuilder]::new(); Stderr = [Text.StringBuilder]::new(); Truncated = $false }
    $callback = {
        param($record,$s)
        $buffer = $(if ($record.Stream -eq 'stdout') { $s.Stdout } else { $s.Stderr })
        if ($buffer.Length+$record.Text.Length -lt 1048576) { [void]$buffer.AppendLine($record.Text) }
        else { $s.Truncated = $true }
    }
    $result = @(FrenchExDev.OPumper2.PoSh\Pump-Me $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory `
        -OnRecord $callback -State $state -TimeoutSeconds $TimeoutSeconds -AsObject)[-1]
    [pscustomobject]@{ Outcome = $result.Outcome; ExitCode = $result.Execution.ExitCode; Error = $result.Error
        Stdout = $state.Stdout.ToString(); Stderr = $state.Stderr.ToString(); Truncated = $state.Truncated }
}

function Invoke-OP2AssemblyGate {
    # The engine assembly gate: the xUnit suite with coverlet line and branch coverage, then Stryker.NET when Mutation
    # is set, each held to 100%. Reports stay in the run's artifacts. A parallel run takes the tests with its checks
    # (Phase Check) and Stryker.NET with the mutation of the package (Phase Mutation).
    # Runtime: the host's .NET SDK, else the pinned SDK container of the build module (Auto); or either one alone.
    param([string]$Root, [string]$Artifacts, [switch]$Mutation, [ValidateSet('All','Check','Mutation')][string]$Phase = 'All',
        [ValidateSet('Auto','Host','Container')][string]$Runtime = 'Auto')
    Import-Module (Join-Path $Root 'build/FrenchExDev.OPumper2.Build.psm1')
    $hostSdk = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue
    $container = $null
    if ($Runtime -eq 'Container' -or ($Runtime -eq 'Auto' -and !$hostSdk)) {
        $container = Resolve-OP2BuildTarget Container -Root $Root
        # A missing SDK is a missing prerequisite, reported as such: the assembly is never declared validated without a run.
        if (!$container.Runtime) { return [ordered]@{ Outcome = 'Failed'; Reason = $(if ($Runtime -eq 'Container') { $container.Reason } else { 'DotnetUnavailable' }) } }
    } elseif (!$hostSdk) { return [ordered]@{ Outcome = 'Failed'; Reason = 'DotnetUnavailable' } }
    $engine = Join-Path $Root 'engine'
    $output = Join-Path $Artifacts 'engine'
    [void][IO.Directory]::CreateDirectory($output)
    $dotnet = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'Invoke-Dotnet.ps1'))
    $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    # One dotnet command in the engine folder: in the container, restores reach the network and the run's artifacts
    # are writable; on the host, through Invoke-Dotnet.ps1 for UTF-8 output.
    $step = {
        param([string[]]$Arguments, [int]$TimeoutSeconds, [switch]$Network)
        if ($container) {
            Invoke-OP2Dotnet $container.Runtime $Arguments -Image $container.Image -Network:$Network -Root $Root -WorkingDirectory 'engine' -Writable @($output) -TimeoutSeconds $TimeoutSeconds
        } else { Invoke-OP2TestTool -FilePath $pwsh -WorkingDirectory $engine -TimeoutSeconds $TimeoutSeconds -ArgumentList ($dotnet + $Arguments) }
    }
    $report = [ordered]@{ Runtime = $(if ($container) { $container.Runtime.Kind } else { 'Host' }); Passed = $null; Failed = $null; Total = $null; LineRate = $null; BranchRate = $null; Mutation = $null; Outcome = 'Failed'; ExitCode = $null }
    $valid = $true
    if ($Phase -ne 'Mutation') {
        # A container runs without network: it restores first, then tests offline.
        $restored = $(if ($container) { & $step @('restore', 'FrenchExDev.OPumper2.Engine.slnx') 1200 -Network } else { $null })
        $test = $(if ($restored -and $restored.Outcome -ne 'Success') { $restored } else {
            & $step (@('test', 'FrenchExDev.OPumper2.Engine.slnx', '--nologo', '--collect:XPlat Code Coverage', '--results-directory', $output, '--logger', 'trx;LogFileName=engine.trx') +
                @($(if ($container) { '--no-restore' }))) 1200 })
        $report.ExitCode = $test.ExitCode; $report.Passed = 0; $report.Failed = 0; $report.Total = 0
        $trx = Get-ChildItem -LiteralPath $output -Recurse -Filter engine.trx -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($trx) {
            $counters = ([xml](Get-Content -LiteralPath $trx.FullName -Raw)).TestRun.ResultSummary.Counters
            $report.Passed = [int]$counters.passed; $report.Failed = [int]$counters.failed; $report.Total = [int]$counters.total
        }
        $coverage = Get-ChildItem -LiteralPath $output -Recurse -Filter coverage.cobertura.xml -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($coverage) {
            $summary = ([xml](Get-Content -LiteralPath $coverage.FullName -Raw)).coverage
            $report.LineRate = [double]$summary.'line-rate'; $report.BranchRate = [double]$summary.'branch-rate'
        }
        $valid = ($test.Outcome -eq 'Success' -and $report.Total -gt 0 -and $report.Passed -eq $report.Total -and $report.LineRate -eq 1 -and $report.BranchRate -eq 1)
    }
    if ($Mutation -and $Phase -ne 'Check') {
        $restore = & $step @('tool', 'restore') 600 -Network
        # The container also restores the projects Stryker.NET builds, since it then runs offline.
        if ($container -and $restore.Outcome -eq 'Success') { $restore = & $step @('restore', 'FrenchExDev.OPumper2.Engine.slnx') 1200 -Network }
        $stryker = Join-Path $output 'stryker'
        $run = & $step @('stryker', '--project', 'FrenchExDev.OPumper2.Engine.csproj', '--test-project', 'FrenchExDev.OPumper2.Engine.Tests/FrenchExDev.OPumper2.Engine.Tests.csproj',
            '--threshold-high', '100', '--threshold-low', '100', '--break-at', '100', '--reporter', 'json', '--output', $stryker) 3600
        $report.Mutation = [ordered]@{ Score = $null; Detected = 0; Undetected = @(); ExitCode = $run.ExitCode; Restore = $restore.Outcome }
        $json = Join-Path $stryker 'reports/mutation-report.json'
        if (Test-Path -LiteralPath $json) {
            $files = (Get-Content -LiteralPath $json -Raw | ConvertFrom-Json -AsHashtable).files
            $undetected = [Collections.Generic.List[string]]::new()
            foreach ($file in $files.Keys) {
                foreach ($mutant in $files[$file].mutants) {
                    # Timed-out mutants are detected; compile errors and ignored mutants are not scored.
                    if ($mutant.status -in @('Killed', 'Timeout')) { $report.Mutation.Detected++ }
                    elseif ($mutant.status -in @('Survived', 'NoCoverage')) { $undetected.Add("$([IO.Path]::GetFileName($file)):$($mutant.location.start.line) $($mutant.mutatorName) ($($mutant.status))") }
                }
            }
            $scored = $report.Mutation.Detected + $undetected.Count
            if ($scored) { $report.Mutation.Score = [Math]::Round(100 * $report.Mutation.Detected / $scored, 2) }
            $report.Mutation.Undetected = @($undetected | Select-Object -First 10)
        }
        if ($run.Outcome -ne 'Success' -or $report.Mutation.Score -ne 100) { $valid = $false }
    }
    if ($valid) { $report.Outcome = 'Success' }
    $report
}

function Invoke-OP2PackageRun {
    # One package's part of a parallel run, in its own process: its report, or a failed report naming why there is none.
    param([string]$Package, [string[]]$ArgumentList, [int]$TimeoutSeconds)
    $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $run = Invoke-OP2TestTool -FilePath $pwsh -TimeoutSeconds $TimeoutSeconds -ArgumentList (@('-NoProfile', '-NonInteractive', '-File',
        (Join-Path $PSScriptRoot 'Invoke-Tests.ps1'), '-Package', $Package, '-Serial') + $ArgumentList)
    $line = $run.Stdout -split "`r?`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1
    $summary = $null
    if ($line) { try { $summary = $line | ConvertFrom-Json -AsHashtable } catch { $summary = $null } }
    if ($summary -and @($summary['Reports']).Count) { return $summary['Reports'][0] }
    [ordered]@{ Package = $Package; Outcome = 'Failed'
        Error = $(if ($summary -and $summary['Error']) { $summary['Error'] } else { @{ Outcome = $run.Outcome; ExitCode = $run.ExitCode; Message = $run.Error.Message; Truncated = $run.Truncated } }) }
}

function Merge-OP2PackageReport {
    # A package's report from its two processes: its checks, then the mutation of its sources and of its assembly.
    param([Collections.IDictionary]$Check, [Collections.IDictionary]$Mutation)
    $report = [ordered]@{}
    foreach ($key in $Check.get_Keys()) { $report[$key] = $Check[$key] }
    if ($null -ne $Mutation['Mutation']) { $report['Mutation'] = $Mutation['Mutation'] }
    if ($Mutation['Assembly']) {
        if (!$report['Assembly']) { $report['Assembly'] = [ordered]@{ Outcome = 'Success' } }
        $report['Assembly']['Mutation'] = $Mutation['Assembly']['Mutation']
        if ($Mutation['Assembly']['Outcome'] -ne 'Success') { $report['Assembly']['Outcome'] = 'Failed' }
    }
    if ($Mutation['Error']) { $report['MutationError'] = $Mutation['Error'] }
    if ($Mutation['Outcome'] -ne 'Success') { $report['Outcome'] = 'Failed' }
    $report
}

function Copy-OP2TestTree {
    param([string]$Source, [string]$Destination)
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($item.Name -in @('.git','.cache','Artifacts')) { continue }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) { Copy-OP2TestTree $item.FullName $target }
        else { [IO.File]::Copy($item.FullName,$target,$true) }
    }
}
