#requires -Version 7.6
<#
.SYNOPSIS
Builds the OPumper2 engine assembly, its tests or its pinned runtime dependencies, with or without a .NET SDK on the machine.

.DESCRIPTION
Auto uses Podman, then Docker, then the host's dotnet. A container build runs in the SDK image pinned by digest in
build/container-images.lock.json (UpdateImages pulls and pins it again), with the package mounted read-only, its .cache
writable, a persistent NuGet cache, and the network only during restores. The result is one compact JSON line:
Outcome, Runtime, Image, Steps (each with its exit code and at most 20 error lines) and Reason when it failed.

.EXAMPLE
./build/Build-Engine.ps1                       # engine assembly, best available runtime
./build/Build-Engine.ps1 -Runtime Podman -Test # engine and its xUnit suite in the SDK container
./build/Build-Engine.ps1 -Project Engine,Dependencies -Runtime Host
#>
[CmdletBinding()]
param([ValidateSet('Auto','Podman','Docker','Host')][string]$Runtime = 'Auto',
    [ValidateSet('Engine','Dependencies')][string[]]$Project = @('Engine'),
    [ValidateSet('Debug','Release')][string]$Configuration = 'Release',
    [switch]$Test, [switch]$UpdateImages)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'FrenchExDev.OPumper2.Build.psm1') -Force
    $result = Invoke-OPumper2EngineBuild -Runtime $Runtime -Project $Project -Configuration $Configuration -Test:$Test -UpdateImages:$UpdateImages
    $result | ConvertTo-Json -Depth 6 -Compress -EscapeHandling EscapeNonAscii
    if ($result.Outcome -ne 'Success') { exit 1 }
} catch {
    @{ Outcome = 'Failed'; Error = @{ Type = $_.Exception.GetType().FullName; Message = $_.Exception.Message } } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
    exit 1
}
