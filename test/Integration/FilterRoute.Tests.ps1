BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    # A catalogue routed on pwsh itself: generated scripts stand for any tool, so no real work repository is touched.
    $script:Catalogue = Join-Path $TestDrive 'catalogue'
    [void][IO.Directory]::CreateDirectory($script:Catalogue)
    [IO.File]::WriteAllText((Join-Path $script:Catalogue 'workload.psd1'), @'
@{ Filters = @(@{
    Id = 'workload'; Routes = @('pwsh -NonInteractive', 'pwsh -NoLogo', 'pwsh -Interactive'); Description = 'Generated workload.'; Source = 'test'
    Arguments = @('-NoProfile'); Drop = @('^DEBUG ')
    Counters = @{ Items = '^INFO item'; Total = 'size=(?<sum>\d+)' }
    Groups = @{ Failures = '^ERROR (?<key>E\d+)' }
    Captures = @{ Final = '^done (?<text>.+)$' }
    Keep = @('^ERROR ')
}) }
'@)
    # An exact route stays with its contributor; a shorter prefix route does not hide a longer filter route.
    Register-OPumper2 -Id 'existing' -Route @('pwsh','-NonInteractive') -Handler { param($call) } -ProviderId tests | Out-Null
    Register-OPumper2 -Id 'prefix' -Route @('pwsh') -Handler { param($call) } -ProviderId tests | Out-Null
    Register-OPumper2Filter -Path $script:Catalogue | Out-Null
    $script:Generator = Join-Path $TestDrive 'generate.ps1'
    [IO.File]::WriteAllText($script:Generator, @'
param([int]$Count, [int]$ExitCode, [switch]$Quiet)
$writer = [Console]::Out
for ($index = 1; $index -le $Count; $index++) {
    if ($Quiet) { $writer.WriteLine("DEBUG $index"); continue }
    $writer.WriteLine("DEBUG tick $index")
    $writer.WriteLine("`e[32mINFO item $index size=2`e[0m")
    if ($index % 100 -eq 0) { $writer.WriteLine("ERROR E$($index % 7) item failed") }
}
$writer.WriteLine("done $Count items")
exit $ExitCode
'@)
}

AfterAll { foreach ($id in @('existing','prefix','workload (pwsh -NoLogo)','workload (pwsh -Interactive)')) { Unregister-OPumper2 $id | Out-Null } }

Describe 'Routed catalogue filters' {
    It 'keeps a route another contributor registered and takes the free ones' {
        (Resolve-OPumper2Command pwsh -NonInteractive -File x).Id | Should -BeExactly 'existing'
        $resolved = Resolve-OPumper2Command pwsh -NoLogo -File x
        # The Id of a route follows its position in the filter: the first route, taken here, would have the plain Id.
        "$($resolved.Id)|$($resolved.ProviderId)|$($resolved.Route -join ' ')" | Should -BeExactly 'workload (pwsh -NoLogo)|filters|pwsh -NoLogo'
        (Resolve-OPumper2Command pwsh -Interactive).Id | Should -BeExactly 'workload (pwsh -Interactive)'
        (Resolve-OPumper2Command pwsh -Version).Id | Should -BeExactly 'prefix'
    }
    It 'reduces a generated 40,000-line workload to its counters, groups and repeated failures' {
        $result = pump -AsObject pwsh -NoLogo -File $script:Generator -Count 20000 -ExitCode 3
        "$($result.Outcome)|$($result.Error.Code)|$($result.Execution.ExitCode)" | Should -BeExactly 'Failed|NativeFailed|3'
        $report = $result.Data
        "$($report.Lines)|$($report.Dropped)|$($report.Counters.Items)|$($report.Counters.Total)|$($report.Captures.Final)" | Should -BeExactly '40201|20000|20000|40000|20000 items'
        (@($report.Groups.Failures.Values) | Measure-Object -Sum).Sum | Should -Be 200
        (@($report.Kept | ForEach-Object Occurrences) | Measure-Object -Sum).Sum | Should -Be 200
        $report.Kept.Count | Should -Be 7
        $result.Presentation.ExcerptLines | Should -Be 0
        $text = pump -AsJson pwsh -NoLogo -File $script:Generator -Count 20000 -ExitCode 3
        $delivered = $text | ConvertFrom-Json -AsHashtable -NoEnumerate
        $delivered[0].ContainsKey('Excerpt') | Should -BeFalse
        $delivered[0].Data.Kept | Should -Match '^ERROR E\d item failed \(x2[89]\)$'
        ($text -join "`n").Length | Should -BeLessThan ($delivered[0].Measurement.SourceBytes / 100)
    }
    It 'keeps the excerpt of a failure the filter does not explain' {
        $delivered = pump -AsJson pwsh -NoLogo -File $script:Generator -Count 3 -ExitCode 2 -Quiet | ConvertFrom-Json -AsHashtable -NoEnumerate
        "$($delivered[0].Outcome)|$($delivered[0].Data.Lines)" | Should -BeExactly 'Failed|4'
        ($delivered[0].Excerpt.Stdout.Tail -join '|') | Should -Match 'done 3 items$'
        $quiet = pump -AsObject pwsh -NoLogo -File $script:Generator -Count 3 -ExitCode 0 -Quiet
        "$($quiet.Outcome)|$($quiet.Data.Kept.Count)|$($quiet.Data.Dropped)" | Should -BeExactly 'Success|0|3'
    }
}
