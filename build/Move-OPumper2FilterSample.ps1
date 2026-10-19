#requires -Version 7.6
<#
.SYNOPSIS
Moves the recorded samples of each pump module (test/Fixtures/samples.psd1) into its filters, as their built-in Tests.

.DESCRIPTION
Each sample becomes a test of the filter it names: Name, ExitCode, Lines and Expect. The test is inserted at the end of
the filter's entry, found in the parsed catalogue file, so the rest of the file (comments and layout included) stays as
it is. Without -Apply the script only reports what it would move; with -Apply it writes the catalogues and removes the
samples file. It prints one compact JSON line.
#>
[CmdletBinding()]
param([switch]$Apply, [string]$Root = (Split-Path (Split-Path $PSScriptRoot)))
$ErrorActionPreference = 'Stop'

function ConvertTo-SampleLiteral {
    # A PowerShell data literal of a sample value: strings quoted, arrays as @(...), mappings as @{ ... }.
    param([object]$Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    if ($Value -is [Collections.IDictionary]) {
        $pairs = foreach ($key in @(@($Value.get_Keys()) | Sort-Object)) {
            $name = $(if ($key -match '^[A-Za-z_][A-Za-z0-9_]*$') { $key } else { ConvertTo-SampleLiteral ([string]$key) })
            "$name = $(ConvertTo-SampleLiteral $Value[$key])"
        }
        return '@{ ' + ($pairs -join '; ') + ' }'
    }
    return '@(' + (@($Value | ForEach-Object { ConvertTo-SampleLiteral $_ }) -join ', ') + ')'
}

$report = [ordered]@{ Applied = [bool]$Apply; Modules = [Collections.Generic.List[string]]::new(); Tests = 0; Unmatched = [Collections.Generic.List[string]]::new() }
foreach ($module in @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'FrenchExDev.OPumper2.*.PoSh')) {
    $samplesPath = Join-Path $module.FullName 'test/Fixtures/samples.psd1'
    if (!(Test-Path -LiteralPath $samplesPath)) { continue }
    $samples = @((Import-PowerShellDataFile -LiteralPath $samplesPath).Samples)
    $byFilter = @{}
    foreach ($sample in $samples) { if (!$byFilter.ContainsKey($sample.Filter)) { $byFilter[$sample.Filter] = [Collections.Generic.List[object]]::new() }; $byFilter[$sample.Filter].Add($sample) }
    $placed = [Collections.Generic.HashSet[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $module.FullName 'filters') -Filter '*.psd1' -File)) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
        $insertions = [Collections.Generic.List[object]]::new()
        $entries = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true)
        foreach ($entry in $entries) {
            $id = $entry.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'Id' } | ForEach-Object { $_.Item2.Extent.Text.Trim("'", '"', ' ') } | Select-Object -First 1
            if (!$id -or !$byFilter.ContainsKey($id)) { continue }
            # The closing brace stands alone on its line: the tests go on the lines before it, one level deeper.
            $close = $entry.Extent.EndOffset - 1
            $lineStart = $text.LastIndexOf("`n", $close) + 1
            if ($text.Substring($lineStart, $close - $lineStart).Trim()) { throw "$($file.Name): the entry $id must end with its closing brace on a line of its own." }
            $indent = ' ' * ($entry.Extent.StartColumnNumber + 3)
            $newline = $(if ($text.Contains("`r`n")) { "`r`n" } else { "`n" })
            $index = 0
            $tests = foreach ($sample in $byFilter[$id]) {
                $index++
                $test = [ordered]@{ Name = $(if ($sample.Contains('Name')) { $sample.Name } elseif ($byFilter[$id].Count -gt 1) { "recorded sample $index" } else { 'recorded sample' }) }
                if ($sample.Contains('ExitCode')) { $test.ExitCode = $sample.ExitCode }
                $test.Lines = @($sample.Lines); $test.Expect = $sample.Expect
                if ($sample.Contains('Absent')) { $test.Absent = @($sample.Absent) }
                $parts = foreach ($key in $test.Keys) { "$key = $(ConvertTo-SampleLiteral $test[$key])" }
                "$indent    @{ $($parts -join '; ') }"
            }
            $insertions.Add([pscustomobject]@{ Offset = $lineStart; Text = "${indent}Tests = @($newline" + ($tests -join $newline) + "$newline$indent)$newline" })
            [void]$placed.Add($id); $report.Tests += $byFilter[$id].Count
        }
        if ($insertions.Count -and $Apply) {
            foreach ($insertion in @($insertions | Sort-Object Offset -Descending)) { $text = $text.Insert($insertion.Offset, $insertion.Text) }
            [IO.File]::WriteAllText($file.FullName, $text, [Text.UTF8Encoding]::new($false))
        }
    }
    foreach ($id in $byFilter.Keys) { if (!$placed.Contains($id)) { $report.Unmatched.Add("$($module.Name): $id") } }
    $report.Modules.Add("$($module.Name) ($($samples.Count))")
    if ($Apply -and !$report.Unmatched.Count) {
        Remove-Item -LiteralPath $samplesPath
        $fixtures = Split-Path $samplesPath
        if (!@(Get-ChildItem -LiteralPath $fixtures -Force).Count) { Remove-Item -LiteralPath $fixtures }
    }
}
$report | ConvertTo-Json -Compress
