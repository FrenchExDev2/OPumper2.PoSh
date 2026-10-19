#requires -Version 7.6
[CmdletBinding()]
param([ValidateSet('Engine','Git','Dotnet','Node','Python','Rust','Go','Make','Jvm','Containers','Kubernetes','Systemd','GitHub','Terraform','Search','Agent','All')][string]$Package = 'All',
    [ValidateSet('stable')][string[]]$Runtime = @('stable'), [switch]$Mutation,
    [switch]$UpdateImages,
    # Forwarded to Invoke-Tests.ps1 inside the container; workers then share the Podman machine's CPUs.
    [ValidateRange(0,64)][Nullable[int]]$Workers)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# A caller's pump decodes this output strictly as UTF-8; localized messages would otherwise come in the console code page.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$engine = Split-Path $PSScriptRoot; $parent = Split-Path $engine
$env:PSModulePath = (Join-Path $engine '.cache/Modules')+[IO.Path]::PathSeparator+$env:PSModulePath
$artifacts = Join-Path $PSScriptRoot 'Artifacts/linux'; [void][IO.Directory]::CreateDirectory($artifacts)
Import-Module (Join-Path $engine 'FrenchExDev.OPumper2.PoSh.psd1') -DisableNameChecking
# The container runtime and the image pins come from the build module, shared with the engine builds.
Import-Module (Join-Path $engine 'build/FrenchExDev.OPumper2.Build.psm1')
. (Join-Path $PSScriptRoot 'ToolSupport.ps1')
$reports = [Collections.Generic.List[object]]::new()
try {
    $container = @(Resolve-OP2BuildRuntime Auto | Where-Object Kind -ne 'Host') | Select-Object -First 1
    if (!$container) { throw 'Neither Podman nor Docker is available. Install one before running Linux validation.' }
    $tool = $container.Executable
    $info = Invoke-OP2TestTool $tool @('info','--format','json') -TimeoutSeconds 30
    if ($info.Outcome -ne 'Success') {
        # Podman on Windows and macOS runs in a machine, which may need starting; Docker has no such machine.
        if ($container.Kind -ne 'Podman') { throw "$($container.Kind) is unavailable. Start it before running Linux validation." }
        $machines = Invoke-OP2TestTool $tool @('machine','list','--format','json') -TimeoutSeconds 30
        if ($machines.Outcome -ne 'Success' -or $machines.Truncated) { throw 'Podman machine inventory is unavailable.' }
        $machine = @($machines.Stdout | ConvertFrom-Json) | Select-Object -First 1
        if (!$machine) { throw 'No Podman machine is configured. Initialize one before running Linux validation.' }
        $start = Invoke-OP2TestTool $tool @('machine','start',$machine.Name) -TimeoutSeconds 120
        if ($start.Outcome -ne 'Success') { throw 'The configured Podman machine could not start.' }
        $info = Invoke-OP2TestTool $tool @('info','--format','json') -TimeoutSeconds 30
        if ($info.Outcome -ne 'Success') { throw 'Podman remains unavailable after starting the machine.' }
    }
    $lockPath = Join-Path $PSScriptRoot 'container-images.lock.json'
    $versions = Import-PowerShellDataFile (Join-Path $engine 'resources/dependencies.psd1')
    $runtimeVersions = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'runtime-versions.psd1')
    foreach ($version in $Runtime) {
        # Pinned by digest on first use or with UpdateImages, like the SDK image; the image build pulls it if needed.
        $digest = Get-OP2LockedImage $container $lockPath $version 'docker.io/library/alpine:3.24' -Update:$UpdateImages
        $context = Join-Path $engine ('.cache/linux/'+[guid]::NewGuid().ToString('N'))
        try {
            [void][IO.Directory]::CreateDirectory($context)
            # Alpine supplies the OS; the Containerfile downloads and verifies the pinned musl PowerShell build.
            $stable = $runtimeVersions.Stable
            $expectedRuntime = $stable.Version
            # The lock also records the PowerShell build verified in the image.
            $locked = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -AsHashtable
            $locked[$version].RuntimeVersion = $stable.Version
            $locked[$version].ArchiveSHA256 = $stable.LinuxMuslSHA256
            $locked | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $lockPath
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Containerfile') -Destination (Join-Path $context 'Containerfile')
            foreach ($name in (Get-OP2TestPackage).Values) { Copy-OP2TestTree (Join-Path $parent $name) (Join-Path $context "packages/$name") }
            foreach ($name in $versions.Keys) {
                $pinned = Get-Module -ListAvailable $name | Where-Object Version -eq $versions[$name] | Select-Object -First 1
                if (!$pinned) { throw "Missing pinned tool $name. Run Initialize-Dependencies.ps1 -Tools." }
                Copy-OP2TestTree $pinned.ModuleBase (Join-Path $context "tools/$name/$($versions[$name])")
            }
            $hashes = @(Get-ChildItem -LiteralPath $context -Recurse -File | Sort-Object FullName | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
            # Build arguments are not files: the runtime version and checksum must enter the image fingerprint explicitly.
            $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($digest+$stable.Version+$stable.LinuxMuslSHA256+($hashes -join '')))).ToLowerInvariant()
            $tag = 'localhost/opumper2-tests:'+$fingerprint.Substring(0,20)
            # Podman and Docker both answer image inspect; only Podman has image exists.
            $exists = Invoke-OP2TestTool $tool @('image','inspect','--format','{{.Id}}',$tag)
            if ($exists.ExitCode -ne 0) {
                $build = Invoke-OP2TestTool $tool @('build','--quiet','--build-arg',"BASE_IMAGE=$digest",'--build-arg',"PWSH_VERSION=$($stable.Version)",
                    '--build-arg',"PWSH_SHA256=$($stable.LinuxMuslSHA256.ToLowerInvariant())",'-t',$tag,$context) -TimeoutSeconds 1200
                if ($build.Outcome -ne 'Success') {
                    # The last lines of the build say why; quiet builds write their errors to stderr.
                    $tail = @("$($build.Stderr)`n$($build.Stdout)" -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 8) -join ' | '
                    throw "Test image build failed for ${version} (exit $($build.ExitCode), $($build.Error.Code) $($build.Error.Message)): $tail"
                }
            }
        } finally {
            # The build context is owned by this run and is useless once the image exists.
            if (Test-Path -LiteralPath $context) { Remove-Item -LiteralPath $context -Recurse -Force }
        }
        $name = 'opumper2-test-'+[guid]::NewGuid().ToString('N')
        $created = $false
        try {
            $arguments = @('create','--name',$name,'--network=none',$tag,'-Package',$Package,'-ExpectedRuntime',$expectedRuntime)
            if ($Mutation) { $arguments += '-Mutation' }
            if ($null -ne $Workers) { $arguments += @('-Workers',[string]$Workers) }
            $create = Invoke-OP2TestTool $tool $arguments
            if ($create.Outcome -ne 'Success') { throw 'Test container creation failed.' }
            $created = $true
            $run = Invoke-OP2TestTool $tool @('start','--attach',$name) -TimeoutSeconds 7200
            $destination = Join-Path $artifacts $version; [void][IO.Directory]::CreateDirectory($destination)
            $copy = Invoke-OP2TestTool $tool @('cp',"${name}:/artifacts/.",$destination)
            $lastJson = @($run.Stdout -split "`r?`n" | Where-Object { $_.StartsWith('{') }) | Select-Object -Last 1
            $details = $(if ($lastJson) { $lastJson | ConvertFrom-Json } else { $null })
            $reports.Add(@{ Runtime = $version; ContainerRuntime = $container.Kind; Image = $tag; BaseDigest = $digest; ExitCode = $run.ExitCode
                Outcome = $(if ($run.Outcome -eq 'Success' -and $copy.Outcome -eq 'Success') { 'Success' } else { 'Failed' }); ReportsCopied = ($copy.Outcome -eq 'Success')
                Details = $details })
        } finally {
            if ($created) { $cleanup = Invoke-OP2TestTool $tool @('rm','--force',$name); if ($cleanup.Outcome -ne 'Success') { throw 'Owned container cleanup failed.' } }
        }
    }
    $failed = @($reports | Where-Object Outcome -ne 'Success').Count
    @{ Outcome = $(if ($failed) { 'Failed' } else { 'Success' }); Reports = $reports.ToArray() } | ConvertTo-Json -Depth 14 -Compress
    if ($failed) { exit 1 }
} catch { @{ Outcome = 'Failed'; Error = @{ Type = $_.Exception.GetType().FullName; Message = $_.Exception.Message }; Reports = $reports.ToArray() } | ConvertTo-Json -Depth 14 -Compress; exit 1 }
