function ConvertTo-OPumper2FilterSummary {
    # The delivered projection of a filter report: lines read, counters and captures, groups by frequency, then the kept
    # lines with their repetitions. Groups give way to the budget before kept lines; Omitted counts what went.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Report, [Collections.IDictionary]$Settings = @{ MaxItems = 20 })
    $summary = [ordered]@{ Filter = $Report.Filter; Succeeded = $Report.Succeeded; Lines = $Report.Lines }
    $counters = [ordered]@{}
    foreach ($name in $Report.Counters.Keys) { if ($null -ne $Report.Counters[$name]) { $counters[$name] = $Report.Counters[$name] } }
    if ($counters.Count) { $summary.Counters = $counters }
    $captures = [ordered]@{}
    foreach ($name in $Report.Captures.Keys) { if ($null -ne $Report.Captures[$name]) { $captures[$name] = ConvertTo-OPumper2Line $Report.Captures[$name] } }
    if ($captures.Count) { $summary.Captures = $captures }
    $names = [Collections.Generic.List[string]]::new()
    foreach ($name in $Report.Groups.Keys) {
        if (!$Report.Groups[$name].Count) { continue }
        $sorted = [ordered]@{}
        foreach ($entry in @($Report.Groups[$name].GetEnumerator() | Sort-Object @{ Expression = 'Value'; Descending = $true }, Key)) { $sorted[$entry.Key] = $entry.Value }
        $summary[$name] = $sorted
        $names.Add($name)
    }
    if ($Report.Kept.Count) {
        $summary.Kept = @($Report.Kept | ForEach-Object {
            $line = ConvertTo-OPumper2Line $_.Text
            if ($_.Occurrences -gt 1) { "$line (x$($_.Occurrences))" } else { $line }
        })
        $names.Add('Kept')
    }
    return Limit-OPumper2Projection $summary $names.ToArray() $Settings
}
