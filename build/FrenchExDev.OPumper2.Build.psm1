#requires -Version 7.6
# Builds the .NET parts of OPumper2 (the engine assembly, its tests and the pinned runtime dependencies) on the host or
# in a pinned SDK container, so a machine without the .NET SDK can build them with Podman or Docker. Each function has
# one job: choosing the runtime, pinning the image, composing the container command, running a bounded process, and
# the build itself composes them. Nothing here depends on the engine module: the first build happens before the engine
# assembly exists.
Set-StrictMode -Version Latest

$script:BuildRoot = Split-Path $PSScriptRoot
$script:SdkImage = 'mcr.microsoft.com/dotnet/sdk:10.0'
$script:ContainerSource = '/src'

function Resolve-OP2BuildRuntime {
    # The runtimes a build may use, in order: the one requested, or with Auto those available among Podman, Docker,
    # then the host's .NET SDK. A runtime whose executable is missing is not returned.
    [CmdletBinding()]
    param([ValidateSet('Auto','Podman','Docker','Host')][string]$Runtime = 'Auto')
    $candidates = $(if ($Runtime -eq 'Auto') { @('Podman','Docker','Host') } else { @($Runtime) })
    $executables = @{ Podman = 'podman'; Docker = 'docker'; Host = 'dotnet' }
    foreach ($kind in $candidates) {
        $command = Get-Command $executables[$kind] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { [pscustomobject]@{ Kind = $kind; Executable = $command.Source } }
    }
}

function Invoke-OP2BuildProcess {
    # A native process with bounded results: through pump when the engine module is loaded, otherwise read directly,
    # since the first build runs before the engine assembly exists. Either way only the exit code, the error lines (at
    # most 20) and the first output line come back, never the raw output.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [string]$WorkingDirectory = (Get-Location).Path,
        [hashtable]$Environment = @{}, [ValidateRange(1,86400)][int]$TimeoutSeconds = 1800)
    $pattern = '(?i)\b(error|failed|denied|not found|unable)\b'
    $pump = Get-Command FrenchExDev.OPumper2.PoSh\Pump-Me -ErrorAction SilentlyContinue
    if ($pump) {
        $state = @{ Errors = [Collections.Generic.List[string]]::new(); Pattern = $pattern; First = $null; Tail = [Collections.Generic.Queue[string]]::new() }
        $completion = @(& $pump $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -Environment $Environment -TimeoutSeconds $TimeoutSeconds -State $state -AsObject -OnRecord {
            param($record, $state)
            $text = $record.Text.Trim()
            if ($null -eq $state.First -and $record.Stream -eq 'stdout' -and $text) { $state.First = $text }
            if ($state.Errors.Count -lt 20 -and $record.Text -match $state.Pattern) { $state.Errors.Add($text) }
            if ($text) { $state.Tail.Enqueue($text); if ($state.Tail.Count -gt 5) { [void]$state.Tail.Dequeue() } }
        }) | Select-Object -Last 1
        # Error lines explain a failure, or its last lines when none says error; a success's summary lines
        # (0 Error(s), Failed: 0) are not errors.
        $failure = $(if ($state.Errors.Count) { $state.Errors.ToArray() } else { $state.Tail.ToArray() })
        return [pscustomobject]@{ Outcome = $completion.Outcome; ExitCode = $completion.Execution.ExitCode
            Errors = $(if ($completion.Outcome -ne 'Success') { $failure } else { @() }); FirstLine = $state.First
            Message = $(if ($completion.Error) { $completion.Error['Message'] }) }
    }
    $info = [Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $info.ArgumentList.Add($argument) }
    $info.WorkingDirectory = $WorkingDirectory; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new(); $info.StandardErrorEncoding = [Text.UTF8Encoding]::new()
    foreach ($name in $Environment.get_Keys()) { $info.Environment[$name] = [string]$Environment[$name] }
    try { $process = [Diagnostics.Process]::Start($info) }
    catch { return [pscustomobject]@{ Outcome = 'Failed'; ExitCode = $null; Errors = @(); FirstLine = $null; Message = $_.Exception.Message } }
    try {
        $errors = $process.StandardError.ReadToEndAsync(); $output = $process.StandardOutput.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            return [pscustomobject]@{ Outcome = 'Timeout'; ExitCode = $null; Errors = @(); FirstLine = $null; Message = $null }
        }
        $stdout = @($output.Result -split "`r?`n")
        $all = @($stdout + @($errors.Result -split "`r?`n"))
        $lines = @($all | Where-Object { $_ -match $pattern } | Select-Object -First 20 | ForEach-Object { $_.Trim() })
        if (!$lines.Count) { $lines = @($all | Where-Object { $_.Trim() } | Select-Object -Last 5 | ForEach-Object { $_.Trim() }) }
        $first = $stdout | Where-Object { $_.Trim() } | Select-Object -First 1
        [pscustomobject]@{ Outcome = $(if ($process.ExitCode -eq 0) { 'Success' } else { 'Failed' }); ExitCode = $process.ExitCode; Errors = $(if ($process.ExitCode -eq 0) { @() } else { $lines })
            FirstLine = $(if ($first) { $first.Trim() }); Message = $null }
    } finally { $process.Dispose() }
}

function Get-OP2LockedImage {
    # The digest reference an image name is pinned to in the lock file. A missing entry, or Update, pulls the image
    # and records its digest; the lock file then changes deliberately, never during an ordinary build.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Runtime, [Parameter(Mandatory)][string]$LockPath, [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Reference, [switch]$Update)
    $lock = [ordered]@{}
    if (Test-Path -LiteralPath $LockPath) {
        $document = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($key in $document.get_Keys()) { $lock[$key] = $document[$key] }
    }
    if (!$Update -and $lock.Contains($Name)) { return $lock[$Name]['Reference'] }
    $pull = Invoke-OP2BuildProcess $Runtime.Executable @('pull', '--quiet', $Reference) -TimeoutSeconds 1800
    if ($pull.Outcome -ne 'Success') { throw "Could not pull $Reference with $($Runtime.Kind): $($pull.Errors -join ' ')" }
    # The repository digest is one short line; anything else is not a digest.
    $inspect = Invoke-OP2BuildProcess $Runtime.Executable @('image', 'inspect', '--format', '{{index .RepoDigests 0}}', $Reference) -TimeoutSeconds 60
    if ($inspect.Outcome -ne 'Success' -or $inspect.FirstLine -notmatch '^\S+@sha256:[0-9a-f]{64}$') { throw "Could not read the digest of $Reference." }
    $lock[$Name] = [ordered]@{ Reference = $inspect.FirstLine; Source = $Reference }
    $lock | ConvertTo-Json | Set-Content -LiteralPath $LockPath
    return $inspect.FirstLine
}

function New-OP2ContainerArgument {
    # The run arguments of a disposable container: mounts (read-only unless Writable), environment, network and the
    # command. Docker on Linux runs as the calling user so the files it writes stay theirs; rootless Podman maps them.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Returns an argument list; nothing runs or changes.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Image, [object[]]$Mount = @(), [hashtable]$Environment = @{},
        [switch]$Network, [string]$WorkingDirectory = $script:ContainerSource, [Parameter(Mandatory)][string[]]$Command, [string]$User)
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('run', '--rm', '--workdir', $WorkingDirectory)) { $arguments.Add($argument) }
    if (!$Network) { $arguments.Add('--network=none') }
    if ($Kind -eq 'Docker' -and $User) { $arguments.Add('--user'); $arguments.Add($User) }
    foreach ($entry in $Mount) {
        $suffix = $(if ($entry.Writable) { '' } else { ':ro' })
        $arguments.Add('--volume'); $arguments.Add("$($entry.Source):$($entry.Target)$suffix")
    }
    foreach ($name in @($Environment.get_Keys() | Sort-Object)) { $arguments.Add('--env'); $arguments.Add("$name=$($Environment[$name])") }
    $arguments.Add($Image)
    foreach ($part in $Command) { $arguments.Add($part) }
    return ,$arguments.ToArray()
}

function Get-OP2BuildUser {
    # The uid:gid Docker runs as on Linux; elsewhere nothing, file ownership needs no mapping there.
    param([string]$Kind, [bool]$Windows = $IsWindows)
    if ($Kind -ne 'Docker' -or $Windows) { return $null }
    return "$(& id '-u'):$(& id '-g')"
}

function Invoke-OP2Dotnet {
    # One dotnet command in the package root, on the host or in the pinned SDK container. Container runs mount the
    # package read-only with its .cache writable, share a persistent NuGet cache, and reach the network only for
    # restores (Network).
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Runtime, [Parameter(Mandatory)][string[]]$ArgumentList, [string]$Image, [switch]$Network,
        [string]$Root = $script:BuildRoot, [string[]]$Writable = @(), [ValidateRange(1,86400)][int]$TimeoutSeconds = 3600,
        # A folder under the root to run in, such as the one holding a local tool manifest.
        [string]$WorkingDirectory = '')
    $environment = @{ DOTNET_CLI_UI_LANGUAGE = 'en-US'; DOTNET_NOLOGO = '1'; DOTNET_CLI_TELEMETRY_OPTOUT = '1' }
    if ($Runtime.Kind -eq 'Host') {
        $directory = $(if ($WorkingDirectory) { Join-Path $Root $WorkingDirectory } else { $Root })
        return Invoke-OP2BuildProcess $Runtime.Executable $ArgumentList -WorkingDirectory $directory -Environment $environment -TimeoutSeconds $TimeoutSeconds
    }
    # A container build keeps its intermediate and build outputs apart from the host's: each records the paths of its
    # own system, and mixing them breaks the test host.
    $cache = Get-OP2BuildCache $Runtime $Root
    $nuget = Join-Path $cache 'nuget'
    [void][IO.Directory]::CreateDirectory($nuget)
    $mounts = [Collections.Generic.List[object]]::new()
    $mounts.Add(@{ Source = $Root; Target = $script:ContainerSource; Writable = $false })
    $mounts.Add(@{ Source = $cache; Target = "$($script:ContainerSource)/.cache"; Writable = $true })
    foreach ($path in $Writable) {
        [void][IO.Directory]::CreateDirectory($path)
        $relative = [IO.Path]::GetRelativePath($Root, $path).Replace('\', '/')
        $mounts.Add(@{ Source = $path; Target = "$($script:ContainerSource)/$relative"; Writable = $true })
    }
    # dotnet refuses to start without an existing home directory.
    [void][IO.Directory]::CreateDirectory((Join-Path $cache 'home'))
    $environment.NUGET_PACKAGES = "$($script:ContainerSource)/.cache/nuget"
    $environment.HOME = "$($script:ContainerSource)/.cache/home"
    $environment.DOTNET_CLI_HOME = "$($script:ContainerSource)/.cache/home"
    # Paths given to dotnet are relative to the package root, which the container mounts at /src.
    $command = @('dotnet') + @($ArgumentList | ForEach-Object { ConvertTo-OP2ContainerPath $_ $Root })
    $directory = $(if ($WorkingDirectory) { "$($script:ContainerSource)/$($WorkingDirectory.Replace('\', '/').Trim('/'))" } else { $script:ContainerSource })
    $arguments = New-OP2ContainerArgument -Kind $Runtime.Kind -Image $Image -Mount $mounts.ToArray() -Environment $environment -Network:$Network -Command $command -User (Get-OP2BuildUser $Runtime.Kind) -WorkingDirectory $directory
    Invoke-OP2BuildProcess $Runtime.Executable $arguments -WorkingDirectory $Root -TimeoutSeconds $TimeoutSeconds
}

function Get-OP2BuildCache {
    # The cache a build writes: the package's .cache on the host, .cache/container in a container, mounted as its .cache.
    param([object]$Runtime, [string]$Root)
    if ($Runtime.Kind -eq 'Host') { return Join-Path $Root '.cache' }
    return Join-Path $Root '.cache/container'
}

function ConvertTo-OP2ContainerPath {
    # A host path under the package root becomes its path in the container; any other argument is kept.
    param([string]$Argument, [string]$Root)
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($Argument.StartsWith($full, [StringComparison]::OrdinalIgnoreCase)) {
        return $script:ContainerSource + $Argument.Substring($full.Length).Replace('\', '/')
    }
    return $Argument
}

function Resolve-OP2BuildTarget {
    # The runtime a build runs with and, for a container, its pinned SDK image. A container runtime whose image cannot
    # be obtained (no registry access, for example) gives way to the next one; each one passed over is reported with
    # its reason. Without any, Reason says why: ImageUnavailable, DotnetUnavailable or ContainerRuntimeUnavailable.
    [CmdletBinding()]
    param([ValidateSet('Auto','Podman','Docker','Host','Container')][string]$Runtime = 'Auto', [string]$Root = $script:BuildRoot, [switch]$UpdateImages)
    $target = [ordered]@{ Runtime = $null; Image = $null; Skipped = [Collections.Generic.List[object]]::new(); Reason = $null }
    # Container: any container runtime, never the host.
    $candidates = $(if ($Runtime -eq 'Container') { @(Resolve-OP2BuildRuntime Auto | Where-Object Kind -ne 'Host') } else { @(Resolve-OP2BuildRuntime $Runtime) })
    foreach ($candidate in $candidates) {
        if ($candidate.Kind -eq 'Host') { $target.Runtime = $candidate; break }
        try { $target.Image = Get-OP2LockedImage $candidate (Join-Path $Root 'build/container-images.lock.json') 'sdk' $script:SdkImage -Update:$UpdateImages; $target.Runtime = $candidate; break }
        catch { $target.Skipped.Add([pscustomobject]@{ Runtime = $candidate.Kind; Reason = 'ImageUnavailable'; Message = $_.Exception.Message }) }
    }
    if (!$target.Runtime) {
        $target.Reason = $(if ($target.Skipped.Count) { 'ImageUnavailable' } elseif ($Runtime -eq 'Host') { 'DotnetUnavailable' } else { 'ContainerRuntimeUnavailable' })
    }
    [pscustomobject]$target
}

function Invoke-OPumper2EngineBuild {
    # Builds the engine assembly (and its tests with Test, Stryker.NET with Mutation) or the pinned runtime
    # dependencies, with the runtime Resolve-OP2BuildRuntime picks. Returns one compact result; every failure names its
    # step and its reason.
    [CmdletBinding()]
    param([ValidateSet('Auto','Podman','Docker','Host')][string]$Runtime = 'Auto', [ValidateSet('Engine','Dependencies')][string[]]$Project = @('Engine'),
        [ValidateSet('Debug','Release')][string]$Configuration = 'Release', [switch]$Test, [switch]$UpdateImages, [string]$Root = $script:BuildRoot)
    $target = Resolve-OP2BuildTarget $Runtime -Root $Root -UpdateImages:$UpdateImages
    $result = [ordered]@{ Outcome = 'Failed'; Runtime = $null; Image = $null; Steps = [Collections.Generic.List[object]]::new(); Skipped = $target.Skipped; Reason = $target.Reason }
    $resolved = $target.Runtime; $image = $target.Image
    if (!$resolved) { return [pscustomobject]$result }
    $result.Runtime = $resolved.Kind; $result.Image = $image
    $projects = @{ Engine = 'engine/FrenchExDev.OPumper2.Engine/FrenchExDev.OPumper2.Engine.csproj'; Dependencies = 'build/Dependencies.csproj' }
    # The runtime dependencies build straight into resources/runtime, which a container must therefore be able to write.
    $outputs = @{ Engine = @(); Dependencies = @(Join-Path $Root 'resources/runtime') }
    $steps = [Collections.Generic.List[object]]::new()
    foreach ($name in $Project) {
        $steps.Add(@{ Name = "$name.Restore"; Network = $true; Arguments = @('restore', $projects[$name]); Writable = @() })
        $steps.Add(@{ Name = "$name.Build"; Network = $false; Arguments = @('build', $projects[$name], '-c', $Configuration, '--no-restore', '--nologo', '-v', 'quiet'); Writable = $outputs[$name] })
    }
    if ($Test) {
        $steps.Add(@{ Name = 'Tests.Restore'; Network = $true; Arguments = @('restore', 'engine/FrenchExDev.OPumper2.Engine.slnx'); Writable = @() })
        $steps.Add(@{ Name = 'Tests'; Network = $false; Arguments = @('test', 'engine/FrenchExDev.OPumper2.Engine.slnx', '--no-restore', '--nologo'); Writable = @() })
    }
    foreach ($step in $steps) {
        $run = Invoke-OP2Dotnet $resolved $step.Arguments -Image $image -Network:$step.Network -Root $Root -Writable $step.Writable
        $result.Steps.Add([pscustomobject]@{ Name = $step.Name; Outcome = $run.Outcome; ExitCode = $run.ExitCode; Errors = $run.Errors })
        if ($run.Outcome -ne 'Success') { $result.Reason = "$($step.Name)Failed"; return [pscustomobject]$result }
    }
    $result.Outcome = 'Success'
    # Where the engine assembly was built, for the copy into resources/runtime.
    $result.EngineAssembly = Join-Path (Get-OP2BuildCache $resolved $Root) 'engine/bin/FrenchExDev.OPumper2.Engine/FrenchExDev.OPumper2.Engine.dll'
    [pscustomobject]$result
}

Export-ModuleMember -Function Invoke-OPumper2EngineBuild, Resolve-OP2BuildRuntime, Resolve-OP2BuildTarget, Invoke-OP2BuildProcess, Get-OP2LockedImage, New-OP2ContainerArgument, Invoke-OP2Dotnet, ConvertTo-OP2ContainerPath
