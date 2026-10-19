$script:OP2GraphWidth = 40

function Format-OP2GainRate {
    param([object]$Rate)
    if ($null -eq $Rate) { return '-' }
    return ([double]$Rate).ToString('P1', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-OP2GainCount {
    # Compact counts for people: 950, 12.3k, 4.1M.
    param([object]$Value)
    if ($null -eq $Value) { return '-' }
    $number = [double]$Value
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    if ([Math]::Abs($number) -ge 1e6) { return ($number / 1e6).ToString('0.#', $invariant) + 'M' }
    if ([Math]::Abs($number) -ge 1e3) { return ($number / 1e3).ToString('0.#', $invariant) + 'k' }
    return $number.ToString('0', $invariant)
}

function Format-OP2Table {
    param([object[]]$Rows)
    return ($Rows | Format-Table -AutoSize | Out-String -Width ([int]::MaxValue)).Trim()
}

function ConvertTo-OP2GainRow {
    # One flat row per measure, shared by text tables and CSV.
    param([string]$Key, [object]$Measure)
    [pscustomobject][ordered]@{ Key = $Key; Deliveries = $Measure.Compared; Captured = $Measure.SourceTokens; Delivered = $Measure.OutputTokens
        Saved = $Measure.SavedTokens; 'Save%' = Format-OP2GainRate $Measure.TokenRate; 'Bytes saved%' = Format-OP2GainRate $Measure.Rate
        Reruns = $Measure.Reruns; Recalled = $Measure.Recalled; Lossy = $Measure.Lossy }
}

function Get-OP2GainTable {
    # The total, then the groups.
    param([Collections.IDictionary]$Data)
    $rows = [Collections.Generic.List[object]]::new()
    $rows.Add((ConvertTo-OP2GainRow 'Total' $Data))
    if ($Data.Contains('Groups')) { foreach ($group in $Data.Groups) { $rows.Add((ConvertTo-OP2GainRow $group.Key $group)) } }
    return $rows.ToArray()
}

function Format-OP2GainGraph {
    param([object[]]$Graph)
    $maximum = (@($Graph | Measure-Object SavedTokens -Maximum)).Maximum
    $lines = foreach ($day in $Graph) {
        $width = $(if ($maximum -gt 0) { [int][Math]::Round([Math]::Max(0, $day.SavedTokens) * $script:OP2GraphWidth / $maximum) } else { 0 })
        '{0} {1} {2}' -f $day.Day, ('#' * $width).PadRight($script:OP2GraphWidth), (Format-OP2GainCount $day.SavedTokens)
    }
    return "Saved tokens per day`n" + (@($lines) -join "`n")
}

function ConvertTo-OP2GainText {
    # Tables and lines for people, like rtk gain.
    param([object]$Result)
    $data = $Result.Data
    $sections = [Collections.Generic.List[string]]::new()
    $sections.Add("OPumper2 gain, $($data.Profile) tokens ($($data.CounterVersion)), $(@($data.Databases) -join ', ')")
    $sections.Add((Format-OP2Table (Get-OP2GainTable $data)))
    $sections.Add("Local objects never delivered: $($data.Local.Invocations) calls, $(Format-OP2GainCount $data.Local.SourceTokens) tokens kept out of context.")
    if ($data.Layers) {
        $sections.Add("Delivered tokens: envelope $(Format-OP2GainCount $data.Layers.Envelope), Data $(Format-OP2GainCount $data.Layers.Data), records $(Format-OP2GainCount $data.Layers.Records), excerpt $(Format-OP2GainCount $data.Layers.Excerpt).")
    }
    if ($data.Alternate) {
        $sections.Add("In $($data.Alternate.Format): $(Format-OP2GainCount $data.Alternate.Tokens) tokens instead of $(Format-OP2GainCount $data.Alternate.Delivered) ($(Format-OP2GainRate $data.Alternate.Rate) smaller).")
    }
    if ($data.Contains('Cost')) {
        $cost = $data.Cost; $invariant = [Globalization.CultureInfo]::InvariantCulture
        $sections.Add("Value at $($cost.TokenPrice) $($cost.Currency) per million tokens: captured $($cost.Captured.ToString('0.####', $invariant)), delivered $($cost.Delivered.ToString('0.####', $invariant)), saved $($cost.Saved.ToString('0.####', $invariant)).")
    }
    if ($data.Contains('Quota')) {
        $sections.Add("Monthly budget $($data.Quota.Month)$(if ($data.Quota['Tier']) { " ($($data.Quota['Tier']))" }): $(Format-OP2GainCount $data.Quota.SavedTokens) of $(Format-OP2GainCount $data.Quota.Budget) tokens saved ($(Format-OP2GainRate $data.Quota.Share)).")
    }
    foreach ($name in @('Top', 'Worst', 'History')) { if ($data.Contains($name)) { $sections.Add("$name`n" + (Format-OP2Table $data[$name])) } }
    if ($data.Contains('Graph')) { $sections.Add((Format-OP2GainGraph $data.Graph)) }
    if ($data.Contains('Advice')) { $sections.Add("Advice`n" + (@($data.Advice | ForEach-Object { "- $($_.Advice)" }) -join "`n")) }
    return $sections -join "`n`n"
}

function ConvertTo-OP2GainCsv {
    # The total and the groups, one record each.
    param([object]$Result)
    return (@(Get-OP2GainTable $Result.Data | ConvertTo-Csv -NoTypeInformation) -join "`n")
}

function ConvertTo-OP2GainLine {
    # One line, for a status line.
    param([object]$Result)
    $data = $Result.Data
    return "OPumper2: $(Format-OP2GainCount $data.SavedTokens) tokens saved ($(Format-OP2GainRate $data.TokenRate)), $($data.Compared) deliveries, $($data.Reruns) reruns, $($data.Recalled) recalls"
}

# Renderers for people; JSON, YAML and objects use the engine's serialization. A new format appends one entry.
$script:OP2GainRenderers = @{
    text = { param($result) ConvertTo-OP2GainText $result }
    csv = { param($result) ConvertTo-OP2GainCsv $result }
    line = { param($result) ConvertTo-OP2GainLine $result }
}
