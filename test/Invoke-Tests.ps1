#requires -Version 7.6
[CmdletBinding()]
param([ValidateSet('Engine','Git','Dotnet','Node','Python','Rust','Go','Make','Jvm','Containers','Kubernetes','Systemd','GitHub','Terraform','Search','Agent','All')][string]$Package = 'All',
    [ValidateSet('Unit','Integration','All')][string]$Suite = 'All',
    [switch]$Analyze, [switch]$Mutation,
    # PSMutant workers: 1 is serial, 0 means processor count minus one. Omitted keeps the package configuration.
    [ValidateRange(0,64)][Nullable[int]]$Workers,
    # Several packages run their checks (Pester, coverage, analyzer, assembly tests) in parallel processes, at most
    # ThrottleLimit at a time, then their mutation one package at a time: each mutation run already uses every core.
    # Serial runs everything in this process, in order.
    [switch]$Serial, [ValidateRange(1,64)][int]$ThrottleLimit = [Environment]::ProcessorCount,
    # Internal to parallel runs: the part a package process runs, and the run its artifacts belong to.
    [ValidateSet('All','Check','Mutation')][string]$Phase = 'All', [string]$RunId,
    # Where the engine assembly gate runs dotnet: the host's SDK, else the pinned SDK container (Auto); or either alone.
    [ValidateSet('Auto','Host','Container')][string]$EngineRuntime = 'Auto')
$ErrorActionPreference = 'Stop'
# A package process writes UTF-8, which its parent's pump decodes strictly; localized messages would otherwise come in
# the console code page. An interactive run keeps its console as it is.
if ($Phase -ne 'All') { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }
$engine = Split-Path $PSScriptRoot
$parent = Split-Path $engine
$env:PSModulePath = (Join-Path $engine '.cache/Modules')+[IO.Path]::PathSeparator+$env:PSModulePath
$reports = [Collections.Generic.List[object]]::new()
$runId = $(if ($RunId) { $RunId } else { [guid]::NewGuid().ToString('N') })
$platform = $(if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' })
. (Join-Path $PSScriptRoot 'ToolSupport.ps1')
$folders = Get-OP2TestPackage
try {
    $packages = $(if ($Package -eq 'All') { @($folders.Keys) } else { @($Package) })
    if (!$Serial -and $Phase -eq 'All' -and $packages.Count -gt 1) {
        # Package processes deliver their compact summaries through pump; the parent merges them in package order.
        $support = Join-Path $PSScriptRoot 'ToolSupport.ps1'
        $manifest = Join-Path $engine 'FrenchExDev.OPumper2.PoSh.psd1'
        # The parent starts the mutation processes itself, through pump.
        Import-Module $manifest -DisableNameChecking
        $checkArguments = @('-Suite', $Suite, '-RunId', $runId, '-Phase', 'Check', '-EngineRuntime', $EngineRuntime) + @($(if ($Analyze) { '-Analyze' })) + @($(if ($Mutation) { '-Mutation' }))
        $checks = @{}
        $packages | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            . $using:support
            Import-Module $using:manifest -DisableNameChecking
            [pscustomobject]@{ Package = $_; Report = Invoke-OP2PackageRun $_ $using:checkArguments 7200 }
        } | ForEach-Object { $checks[$_.Package] = $_.Report }
        foreach ($selected in $packages) {
            $report = $checks[$selected]
            $root = Join-Path $parent $folders[$selected]
            if ($Mutation -and ($selected -eq 'Engine' -or (Test-Path -LiteralPath (Join-Path $root 'test/psmutant.config.json')))) {
                $mutationArguments = @('-RunId', $runId, '-Phase', 'Mutation', '-Mutation', '-EngineRuntime', $EngineRuntime) + @($(if ($null -ne $Workers) { '-Workers'; [string]$Workers }))
                $report = Merge-OP2PackageReport $report (Invoke-OP2PackageRun $selected $mutationArguments 14400)
                $artifacts = Join-Path $root "test/Artifacts/$platform/$($PSVersionTable.PSVersion)/$runId"
                [void][IO.Directory]::CreateDirectory($artifacts)
                $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $artifacts 'summary.json')
            }
            $reports.Add($report)
        }
    } else {
        Import-Module Pester -RequiredVersion 6.2.0 -ErrorAction Stop
        foreach ($selected in $packages) {
            $root = Join-Path $parent $folders[$selected]
            $artifacts = Join-Path $root "test/Artifacts/$platform/$($PSVersionTable.PSVersion)/$runId"
            [void][IO.Directory]::CreateDirectory($artifacts)
            # Catalogue packages have no src: their loader is their only production code.
            $source = Join-Path $root 'src'
            $hasSource = Test-Path -LiteralPath $source -PathType Container
            $report = [ordered]@{ Package = $selected; Runtime = $PSVersionTable.PSVersion.ToString(); Platform = $platform; RunId = $runId; ArtifactPath = $artifacts
                Passed = $null; Failed = $null; Skipped = $null; DiscoveryErrors = $null; Coverage = $null; CoverageTarget = 100; Failures = @(); Discovery = @()
                Analyzer = $null; Mutation = $null; Outcome = 'Failed' }
            # A mutation process checks only what it mutates: its checks ran in their own process.
            $valid = $true
            if ($Phase -ne 'Mutation') {
                $paths = @($(if ($Suite -in @('Unit','All')) { Join-Path $root 'test/Unit' }); $(if ($Suite -in @('Integration','All')) { Join-Path $root 'test/Integration' }))
                $configuration = New-PesterConfiguration
                $configuration.Run.Path = $paths; $configuration.Run.PassThru = $true; $configuration.Run.Parallel = $false
                $configuration.Output.Verbosity = 'None'
                $configuration.TestRegistry.Enabled = $false
                $configuration.TestResult.Enabled = $true; $configuration.TestResult.OutputFormat = 'NUnitXml'
                $configuration.TestResult.OutputPath = Join-Path $artifacts "$Suite.xml"
                $configuration.CodeCoverage.Enabled = $true
                # A package's build module (the engine's build/*.psm1) is production code too.
                $build = @(Get-ChildItem -LiteralPath (Join-Path $root 'build') -Filter '*.psm1' -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
                $configuration.CodeCoverage.Path = @(@($(if ($hasSource) { Join-Path $source '*.ps1' })) + @(Join-Path $root '*.psm1') + $build)
                $configuration.CodeCoverage.CoveragePercentTarget = 100
                $configuration.CodeCoverage.OutputPath = Join-Path $artifacts "$Suite.coverage.xml"
                $result = Invoke-Pester -Configuration $configuration 6>$null
                $coverage = $result.CodeCoverage.CoveragePercent
                $report.Passed = $result.PassedCount; $report.Failed = $result.FailedCount; $report.Skipped = $result.SkippedCount
                $report.DiscoveryErrors = $result.FailedContainersCount; $report.Coverage = $coverage
                $report.Failures = @($result.Failed | Select-Object -First 10 | ForEach-Object {
                    @{ Test = $_.ExpandedPath; Message = ($_.ErrorRecord | ForEach-Object { ($_.Exception.Message -split "`r?`n")[0] } | Select-Object -First 1) }
                })
                $report.Discovery = @($result.FailedContainers | Select-Object -First 3 | ForEach-Object { ($_.ErrorRecord.Exception.Message -split "`r?`n")[0] })
                $valid = ($result.PassedCount -gt 0 -and !$result.FailedCount -and !$result.SkippedCount -and !$result.FailedContainersCount -and $coverage -ge 100)
                if ($Analyze) {
                    Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop
                    $issues = [Collections.Generic.List[object]]::new()
                    if ($hasSource) { $issues.AddRange(@(Invoke-ScriptAnalyzer -Path $source -Recurse -Settings (Join-Path $root 'test/AnalyzerSettings.psd1'))) }
                    $issues.AddRange(@(Invoke-ScriptAnalyzer -Path (Join-Path $root ($folders[$selected]+'.psm1')) -Settings (Join-Path $root 'test/AnalyzerSettings.psd1')))
                    foreach ($module in $build) { $issues.AddRange(@(Invoke-ScriptAnalyzer -Path $module -Settings (Join-Path $root 'test/AnalyzerSettings.psd1'))) }
                    ConvertTo-Json -InputObject @($issues | Select-Object RuleName,Severity,ScriptName,Line,Message) -Depth 8 | Set-Content -LiteralPath (Join-Path $artifacts 'analyzer.json')
                    $report.Analyzer = @{ Issues = $issues.Count; Items = @($issues | Select-Object -First 10 RuleName,ScriptName,Line,Message) }
                    if ($issues.Count) { $valid = $false }
                }
            }
            $mutable = Test-Path -LiteralPath (Join-Path $root 'test/psmutant.config.json')
            if ($Mutation -and !$mutable -and $Phase -ne 'Mutation') {
                # A catalogue package holds data and a loader without operators: there is nothing to mutate. A package with
                # source code but no mutation configuration is a configuration error, never skipped.
                $report.Mutation = @{ Applicable = $false; Reason = $(if ($hasSource) { 'MissingConfiguration' } else { 'CatalogueData' }) }
                if ($hasSource) { $valid = $false }
            }
            if ($Mutation -and $mutable -and $Phase -ne 'Check') {
                Import-Module PSMutant -RequiredVersion 0.6.0 -ErrorAction Stop
                $stage = Join-Path $engine ('.cache/mutations/'+[guid]::NewGuid().ToString('N'))
                # The sandbox is owned by this run: keep only the copied report, even when mutation fails.
                try {
                    foreach ($name in $folders.Values) { Copy-OP2TestTree (Join-Path $parent $name) (Join-Path $stage $name) }
                    # The staged copy of the configuration carries the worker override; the source file is never edited.
                    $mutationConfig = Join-Path $stage ((Split-Path $root -Leaf)+'/test/psmutant.config.json')
                    $settings = Get-Content -LiteralPath $mutationConfig -Raw | ConvertFrom-Json -AsHashtable
                    if ($null -ne $Workers) { $settings.workers = $Workers; $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mutationConfig }
                    $workerCount = $(if ($null -ne $settings.workers) { $settings.workers } else { 1 })
                    $mutationResult = Invoke-PSMutation -ConfigFile $mutationConfig -SourceRoot $stage -Quiet
                    $mutationReport = Join-Path $stage ((Split-Path $root -Leaf)+'/test/Artifacts/mutation.json')
                    if (Test-Path -LiteralPath $mutationReport) { Copy-Item -LiteralPath $mutationReport -Destination (Join-Path $artifacts 'mutation.json') -Force }
                } finally {
                    $stageCleanup = $null
                    try { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
                    catch { $stageCleanup = $_.Exception.Message }
                }
                $mutationReport = Join-Path $artifacts 'mutation.json'
                $report.Mutation = @{ Score = $mutationResult.Score; Killed = $mutationResult.Killed; Total = $mutationResult.Total
                    ExitCode = $mutationResult.ExitCode; FailureReason = $mutationResult.FailureReason; StageCleanupError = $stageCleanup; Workers = $workerCount }
                if (Test-Path -LiteralPath $mutationReport) {
                    $details = Get-Content -LiteralPath $mutationReport -Raw | ConvertFrom-Json
                    $report.Mutation.Equivalent = $details.declaredEquivalent
                    $report.Mutation.TimedOut = $details.timedOut
                }
                if ($mutationResult.ExitCode -ne 0 -or $mutationResult.Total -eq 0 -or $mutationResult.Score -lt 100) { $valid = $false }
            }
            if ($selected -eq 'Engine') {
                # The C# engine assembly has its own gate, held to the same bar: xUnit coverage, then Stryker.NET with -Mutation.
                Import-Module (Join-Path $root 'FrenchExDev.OPumper2.PoSh.psd1') -DisableNameChecking
                $report.Assembly = Invoke-OP2AssemblyGate $root $artifacts -Mutation:$Mutation -Phase $Phase -Runtime $EngineRuntime
                if ($report.Assembly.Outcome -ne 'Success') { $valid = $false }
            }
            if ($valid) { $report.Outcome = 'Success' }
            # A parallel run merges the mutation part into the package summary afterwards.
            $summaryName = $(if ($Phase -eq 'Mutation') { 'summary.mutation.json' } else { 'summary.json' })
            $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $artifacts $summaryName)
            $reports.Add($report)
        }
    }
    $failed = @($reports | Where-Object { $_['Outcome'] -ne 'Success' }).Count
    # Non-ASCII text (localized tool messages) is escaped: the line stays ASCII whatever the console code page.
    @{ Outcome = $(if ($failed) { 'Failed' } else { 'Success' }); Reports = $reports.ToArray(); Runtime = $PSVersionTable.PSVersion.ToString(); OS = [Runtime.InteropServices.RuntimeInformation]::OSDescription } | ConvertTo-Json -Depth 12 -Compress -EscapeHandling EscapeNonAscii
    if ($failed) { exit 1 }
} catch {
    @{ Outcome = 'Failed'; Error = @{ Type = $_.Exception.GetType().FullName; Message = $_.Exception.Message; File = $_.InvocationInfo.ScriptName; Line = $_.InvocationInfo.ScriptLineNumber }; Reports = $reports.ToArray() } | ConvertTo-Json -Depth 8 -Compress -EscapeHandling EscapeNonAscii
    exit 1
}
