#requires -Version 7.6
[CmdletBinding()]
param([switch]$Tools, [switch]$Runtime,
    # Where the .NET builds run: Auto uses Podman, then Docker (in the pinned SDK image), then the host's dotnet.
    [ValidateSet('Auto','Podman','Docker','Host')][string]$BuildRuntime = 'Auto')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$versions = Import-PowerShellDataFile (Join-Path $root 'resources/dependencies.psd1')
$moduleDirectory = Join-Path $root '.cache/Modules'
[void][IO.Directory]::CreateDirectory($moduleDirectory)
$env:PSModulePath = $moduleDirectory+[IO.Path]::PathSeparator+$env:PSModulePath
try {
    if ($Tools -or !$Runtime) {
        foreach ($name in $versions.Keys) {
            if (!(Get-Module -ListAvailable $name | Where-Object { $_.Version -eq $versions[$name] })) {
                Save-PSResource -Name $name -Version $versions[$name] -Path $moduleDirectory -TrustRepository -ErrorAction Stop | Out-Null
            }
        }
    }
    if ($Runtime -or !$Tools) {
        # The module loads the engine assembly when it is imported: build it, and the pinned runtime dependencies, with
        # the build module, which needs neither the engine nor a .NET SDK on the host.
        Import-Module (Join-Path $PSScriptRoot 'FrenchExDev.OPumper2.Build.psm1') -Force
        $build = Invoke-OPumper2EngineBuild -Runtime $BuildRuntime -Project Engine, Dependencies -Root $root
        if ($build.Outcome -ne 'Success') {
            $failed = @($build.Steps | Where-Object Outcome -ne 'Success') | Select-Object -First 1
            throw "The .NET build failed ($($build.Reason), runtime $($build.Runtime)): $(@($(if ($failed) { $failed.Errors }) + @($build.Skipped | ForEach-Object Message)) -join ' ')"
        }
        # A session that imported the module locks the copy: replace it only when the build changed it.
        $engineSource = $build.EngineAssembly
        $engineTarget = Join-Path $root 'resources/runtime/FrenchExDev.OPumper2.Engine.dll'
        [void][IO.Directory]::CreateDirectory((Split-Path $engineTarget))
        if (!(Test-Path -LiteralPath $engineTarget) -or (Get-FileHash -LiteralPath $engineSource).Hash -ne (Get-FileHash -LiteralPath $engineTarget).Hash) {
            Copy-Item -LiteralPath $engineSource -Destination $engineTarget -Force
        }
        $directory = Join-Path $root 'resources/runtime'
        # SQLite ships native libraries for two dozen runtimes; keep the supported ones (the Linux image uses musl).
        $supported = @('win-x64','win-arm64','linux-x64','linux-arm64','linux-musl-x64','linux-musl-arm64','osx-x64','osx-arm64')
        Get-ChildItem -LiteralPath (Join-Path $directory 'runtimes') -Directory | Where-Object Name -notin $supported | Remove-Item -Recurse -Force
        $platform = $(if ($IsWindows) { 'win' } elseif ($IsMacOS) { 'osx' } else { 'linux' })
        $architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
        $file = $(if ($IsWindows) { 'e_sqlite3.dll' } elseif ($IsMacOS) { 'libe_sqlite3.dylib' } else { 'libe_sqlite3.so' })
        $nativeSource = Join-Path $directory "runtimes/$platform-$architecture/native/$file"
        $nativeTarget = Join-Path $directory $file
        if (!(Test-Path -LiteralPath $nativeTarget) -or (Get-FileHash -LiteralPath $nativeSource).Hash -ne (Get-FileHash -LiteralPath $nativeTarget).Hash) {
            Copy-Item -LiteralPath $nativeSource -Destination $nativeTarget -Force
        }
        # Preserve the package metadata and license texts alongside redistributed libraries.
        $assets = Get-Content -LiteralPath (Join-Path $root '.cache/dependencies/project.assets.json') -Raw | ConvertFrom-Json -AsHashtable
        $notices = Join-Path $directory 'notices'; [void][IO.Directory]::CreateDirectory($notices)
        foreach ($library in $assets.libraries.Keys) {
            if ($assets.libraries[$library].type -ne 'package') { continue }
            foreach ($folder in $assets.packageFolders.Keys) {
                $package = Join-Path $folder $assets.libraries[$library].path
                if (!(Test-Path -LiteralPath $package)) { continue }
                foreach ($metadata in Get-ChildItem -LiteralPath $package -File -Filter '*.nuspec') { Copy-Item -LiteralPath $metadata.FullName -Destination (Join-Path $notices (($library -replace '/','-')+'.nuspec')) -Force }
                foreach ($path in $assets.libraries[$library].files) {
                    if ([IO.Path]::GetFileName($path) -match '^(LICENSE|LICENCE|NOTICE|THIRD.PARTY.NOTICES)(\.|$)') {
                        Copy-Item -LiteralPath (Join-Path $package $path) -Destination (Join-Path $notices (($library -replace '/','-')+'-'+[IO.Path]::GetFileName($path))) -Force
                    }
                }
            }
        }
    }
    @{ Outcome = 'Success'; Tools = $versions; RuntimePrepared = [bool]((Test-Path -LiteralPath (Join-Path $root 'resources/runtime/Microsoft.Data.Sqlite.dll')) -and (Test-Path -LiteralPath (Join-Path $root 'resources/runtime/FrenchExDev.OPumper2.Engine.dll'))) } | ConvertTo-Json -Compress
} catch { @{ Outcome = 'Failed'; Error = @{ Type = $_.Exception.GetType().FullName; Message = $_.Exception.Message } } | ConvertTo-Json -Compress; exit 1 }
