#requires -Version 7.6
<#
.SYNOPSIS
Renames the OPumper2 contributor modules to FrenchExDev.OPumper2.<Name>.PoSh (pumps) and
FrenchExDev.OPumper2.Utility.<Name>.PoSh (utilities), with every reference to them.

.DESCRIPTION
Without -Apply the script only reports what it would change: one line per file with its replacement count, and the
folders and module files it would rename. With -Apply it rewrites the references first, then renames the module files
and folders. It is idempotent: a module already renamed is skipped, and a target that exists next to its source is an
error. Test artifacts, caches, the runtime folder and the previous OPumper generation are never touched.

.EXAMPLE
./build/Rename-OPumper2Module.ps1            # report only
./build/Rename-OPumper2Module.ps1 -Apply     # rename
#>
[CmdletBinding()]
param([switch]$Apply,
    # Files outside the modules that name them: the workspace instructions and the user's configuration.
    [string[]]$ExtraFile = @(),
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)))
$ErrorActionPreference = 'Stop'
$repository = Split-Path (Split-Path $Root)
if (!$PSBoundParameters.ContainsKey('ExtraFile')) {
    $ExtraFile = @((Join-Path $repository 'AGENTS.md'), (Join-Path $repository 'CLAUDE.md'), (Join-Path $repository 'FrenchExDev_i2.code-workspace'),
        (Join-Path $HOME '.opumper2/config.yaml'))
}
# Folder renames, in an order where no old name is a prefix of a later one's replacement.
$renames = [ordered]@{
    'FrenchExDev.Git.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Git.PoSh'
    'FrenchExDev.GitHub.OPumper2.PoSh' = 'FrenchExDev.OPumper2.GitHub.PoSh'
    'FrenchExDev.Dotnet.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Dotnet.PoSh'
    'FrenchExDev.Node.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Node.PoSh'
    'FrenchExDev.Python.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Python.PoSh'
    'FrenchExDev.Rust.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Rust.PoSh'
    'FrenchExDev.Go.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Go.PoSh'
    'FrenchExDev.Build.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Make.PoSh'
    'FrenchExDev.Jvm.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Jvm.PoSh'
    'FrenchExDev.Containers.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Containers.PoSh'
    'FrenchExDev.Kubernetes.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Kubernetes.PoSh'
    'FrenchExDev.Systemd.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Systemd.PoSh'
    'FrenchExDev.Terraform.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Terraform.PoSh'
    'FrenchExDev.Search.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Search.PoSh'
    'FrenchExDev.Agent.OPumper2.PoSh' = 'FrenchExDev.OPumper2.Utility.Agent.PoSh'
}
# Rewrites names never spelled out: the module wildcard of the test supports, the catalogue folder template and the
# launcher key of the Build catalogue, which becomes Make.
$rewrites = @(
    @{ Pattern = [regex]::Escape("'FrenchExDev.*OPumper2.PoSh'"); Replacement = "'FrenchExDev.OPumper2*.PoSh'" }
    @{ Pattern = [regex]::Escape('"FrenchExDev.$name.OPumper2.PoSh"'); Replacement = '"FrenchExDev.OPumper2.$name.PoSh"' }
    @{ Pattern = "(?<=ValidateSet\('Engine'[^)]*)'Build'"; Replacement = "'Make'" }
    @{ Pattern = "(?<=@\('Node','Python','Rust','Go',)'Build'"; Replacement = "'Make'" }
)
$extensions = @('.ps1', '.psm1', '.psd1', '.md', '.json', '.yaml', '.yml', '.code-workspace', '.txt')
$skipped = @('Artifacts', '.cache', 'runtime', 'bin', 'obj', '.git', 'node_modules')

function Get-RenameFile {
    # The text files of a module folder, outside artifacts, caches and build outputs.
    param([string]$Folder)
    foreach ($item in Get-ChildItem -LiteralPath $Folder -Force) {
        if ($item.PSIsContainer) { if ($item.Name -notin $skipped) { Get-RenameFile $item.FullName } }
        elseif ($item.Extension -in $extensions) { $item.FullName }
    }
}

$modules = @(Get-ChildItem -LiteralPath $Root -Directory | Where-Object { $_.Name -eq 'FrenchExDev.OPumper2.PoSh' -or $_.Name -in $renames.Keys -or $_.Name -in $renames.Values })
# This script names the old modules on purpose and keeps them.
$files = @(@($modules | ForEach-Object { Get-RenameFile $_.FullName }) + @($ExtraFile | Where-Object { Test-Path -LiteralPath $_ }) | Where-Object { $_ -ne $PSCommandPath })
$report = [ordered]@{ Applied = [bool]$Apply; Files = [Collections.Generic.List[string]]::new(); Folders = [Collections.Generic.List[string]]::new(); Conflicts = [Collections.Generic.List[string]]::new() }
foreach ($old in $renames.Keys) {
    $source = Join-Path $Root $old; $target = Join-Path $Root $renames[$old]
    if ((Test-Path -LiteralPath $source) -and (Test-Path -LiteralPath $target)) { $report.Conflicts.Add($renames[$old]) }
}
if ($report.Conflicts.Count) { $report | ConvertTo-Json -Compress; exit 1 }
foreach ($file in $files) {
    $text = [IO.File]::ReadAllText($file)
    $updated = $text; $count = 0
    foreach ($old in $renames.Keys) {
        $count += ([regex]::Matches($updated, [regex]::Escape($old))).Count
        $updated = $updated.Replace($old, $renames[$old])
    }
    foreach ($rule in $rewrites) {
        $count += ([regex]::Matches($updated, $rule.Pattern)).Count
        $updated = [regex]::Replace($updated, $rule.Pattern, $rule.Replacement)
    }
    if ($count) {
        $report.Files.Add("$([IO.Path]::GetRelativePath($repository, $file)) ($count)")
        if ($Apply) { [IO.File]::WriteAllText($file, $updated, [Text.UTF8Encoding]::new($false)) }
    }
}
foreach ($old in $renames.Keys) {
    $source = Join-Path $Root $old
    if (!(Test-Path -LiteralPath $source)) { continue }
    $report.Folders.Add("$old -> $($renames[$old])")
    if (!$Apply) { continue }
    foreach ($extension in @('.psd1', '.psm1')) {
        $file = Join-Path $source ($old + $extension)
        if (Test-Path -LiteralPath $file) { Rename-Item -LiteralPath $file -NewName ($renames[$old] + $extension) }
    }
    Rename-Item -LiteralPath $source -NewName $renames[$old]
}
$report | ConvertTo-Json -Compress
