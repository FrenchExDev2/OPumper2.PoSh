#requires -Version 7.6
# Applies the retention policy to generated test state. Never run it while a test launcher is running.
[CmdletBinding(SupportsShouldProcess)]
param([ValidateRange(0,[int]::MaxValue)][int]$KeepRuns = 3, [switch]$Images,
    [ValidateRange(0,[int]::MaxValue)][int]$KeepImages = 1)
$ErrorActionPreference = 'Stop'
$engine = Split-Path $PSScriptRoot; $parent = Split-Path $engine
. (Join-Path $PSScriptRoot 'ToolSupport.ps1')
$packages = @((Get-OP2TestPackage).Values | ForEach-Object { Join-Path $parent $_ })
$removed = [Collections.Generic.List[object]]::new()

function Remove-OP2TestItem {
    [CmdletBinding(SupportsShouldProcess)]
    param([IO.FileSystemInfo]$Item)
    $bytes = $(if ($Item -is [IO.DirectoryInfo]) { [long](Get-ChildItem -LiteralPath $Item.FullName -Recurse -File -Force | Measure-Object Length -Sum).Sum } else { $Item.Length })
    if ($PSCmdlet.ShouldProcess($Item.FullName, 'Remove generated test state')) { Remove-Item -LiteralPath $Item.FullName -Recurse -Force }
    $removed.Add([pscustomobject]@{ Path = [IO.Path]::GetRelativePath($parent, $Item.FullName); Bytes = $bytes })
}

function Clear-OP2ArtifactTree {
    param([string]$Directory, [string[]]$Retained)
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force) {
        if ($item.FullName -in $Retained) { continue }
        $prefix = $item.FullName + [IO.Path]::DirectorySeparatorChar
        if ($item.PSIsContainer -and @($Retained | Where-Object { $_.StartsWith($prefix) }).Count) { Clear-OP2ArtifactTree $item.FullName $Retained; continue }
        Remove-OP2TestItem $item
    }
}

try {
    # Transient staging, diagnostics, stray databases and obsolete archives go; pinned tool and build caches stay.
    $cache = Join-Path $engine '.cache'
    if (Test-Path -LiteralPath $cache) {
        foreach ($item in Get-ChildItem -LiteralPath $cache -Force) {
            if ($item.Name -notin @('Modules','dependencies')) { Remove-OP2TestItem $item }
        }
    }

    # Runs cited as validation evidence are pinned; otherwise keep the newest runs per platform/runtime directory.
    $pinned = @(foreach ($package in $packages) {
        Get-ChildItem -LiteralPath (Join-Path $package 'doc') -Filter '*.md' -File -ErrorAction SilentlyContinue |
            Select-String -Pattern '[0-9a-f]{32}' -AllMatches | ForEach-Object { $_.Matches.Value }
    }) | Sort-Object -Unique
    $retained = [Collections.Generic.List[string]]::new()
    foreach ($package in $packages) {
        $artifacts = Join-Path $package 'test/Artifacts'
        if (!(Test-Path -LiteralPath $artifacts)) { continue }
        $runs = @(Get-ChildItem -LiteralPath $artifacts -Recurse -Directory -Force | Where-Object Name -match '^[0-9a-f]{32}$')
        foreach ($group in ($runs | Group-Object { $_.Parent.FullName })) {
            # A scriptblock, not ForEach-Object -MemberName: the latter honors -WhatIf and would select nothing.
            $newest = @($group.Group | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $KeepRuns | ForEach-Object { $_.FullName })
            foreach ($run in $group.Group) { if ($run.FullName -in $newest -or $run.Name -in $pinned) { $retained.Add($run.FullName) } }
        }
        Clear-OP2ArtifactTree $artifacts $retained.ToArray()
    }

    $imageCount = 0
    if ($Images) {
        $engineModule = Join-Path $engine 'FrenchExDev.OPumper2.PoSh.psd1'
        Import-Module $engineModule -DisableNameChecking
        . (Join-Path $PSScriptRoot 'ToolSupport.ps1')
        $list = Invoke-OP2TestTool podman @('image','ls','--filter','reference=localhost/opumper2-tests','--format','json') -TimeoutSeconds 60
        if ($list.Outcome -ne 'Success' -or $list.Truncated) { throw 'Podman image inventory is unavailable; start the Podman machine first.' }
        $owned = @($(if ($list.Stdout.Trim()) { $list.Stdout | ConvertFrom-Json }) | Sort-Object Created -Descending)
        foreach ($image in @($owned | Select-Object -Skip $KeepImages)) {
            $label = 'podman:' + (@($image.Names) -join ',')
            if ($PSCmdlet.ShouldProcess($label, 'Remove test image')) {
                $removal = Invoke-OP2TestTool podman @('image','rm',$image.Id) -TimeoutSeconds 120
                if ($removal.Outcome -ne 'Success') { throw "Test image removal failed for $label." }
            }
            $removed.Add([pscustomobject]@{ Path = $label; Bytes = [long]$image.Size })
        }
        $imageCount = $owned.Count
    }

    $freed = [long]($removed | Measure-Object Bytes -Sum).Sum
    [ordered]@{ Outcome = 'Success'; WhatIf = [bool]$WhatIfPreference; FreedBytes = $freed; RemovedCount = $removed.Count
        Removed = @($removed | Sort-Object Bytes -Descending | Select-Object -First 50); RetainedRuns = $retained.Count; PinnedRuns = $pinned
        ImagesInspected = $imageCount } | ConvertTo-Json -Depth 5 -Compress
} catch {
    @{ Outcome = 'Failed'; Error = @{ Type = $_.Exception.GetType().FullName; Message = $_.Exception.Message }; RemovedCount = $removed.Count } | ConvertTo-Json -Depth 5 -Compress
    exit 1
}
