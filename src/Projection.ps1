function ConvertTo-OPumper2Line {
    # One delivered line: whitespace flattened, cut at Limit characters (400, the length MSBuild's canonical parser reads)
    # with an ellipsis.
    [CmdletBinding()]
    param([Parameter(Position=0)][AllowNull()][AllowEmptyString()][string]$Text, [ValidateRange(1,[int]::MaxValue)][int]$Limit = 400)
    $flat = ($Text -replace '\s+', ' ').Trim()
    if ($flat.Length -gt $Limit) { return $flat.Substring(0, $Limit) + [char]0x2026 }
    return $flat
}

function Measure-OP2Delivery {
    # Bytes a projection takes once delivered: inside the delivery's envelope when the settings carry it, alone otherwise.
    param([object]$Data, [Collections.IDictionary]$Settings)
    $format = $(if ($Settings['Format']) { $Settings['Format'] } else { 'json' })
    if ($null -eq $Settings['Envelope']) { return [Text.Encoding]::UTF8.GetByteCount((ConvertTo-OP2Document $Data $format)) }
    $probe = $Settings['Envelope'].PSObject.Copy()
    $probe.Data = $Data
    return [Text.Encoding]::UTF8.GetByteCount((ConvertTo-OP2Text @((Protect-OP2Envelope $probe (New-OP2Limit $Settings['ExcerptLines']))) $format -Compact:([bool]$Settings['Compact'])))
}

function Remove-OP2LastEntry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Trims an in-memory projection being built; nothing outside it changes.')]
    # Lists and ordered dictionaries both lose their last entry.
    param([object]$Collection, [int]$Count)
    for ($index = 0; $index -lt $Count; $index++) { $Collection.RemoveAt($Collection.Count - 1) }
}

function Limit-OPumper2Projection {
    # Bounds the named collections of a projection for its delivery: each keeps at most MaxItems entries, then their
    # last entries go, in the order the names are given, until the delivery fits MaxOutputBytes. Omitted counts every
    # dropped entry per collection. Arrays become lists; lists and ordered dictionaries are trimmed in place.
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Projection, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Name,
        [Collections.IDictionary]$Settings = @{})
    $names = @($Name | Where-Object { $Projection.Contains($_) })
    foreach ($key in $names) {
        if ($Projection[$key] -is [array]) { $Projection[$key] = [Collections.Generic.List[object]]::new([object[]]$Projection[$key]) }
    }
    $omitted = [ordered]@{}
    if ($null -ne $Settings['MaxItems']) {
        foreach ($key in $names) {
            $dropped = $Projection[$key].Count - $Settings['MaxItems']
            if ($dropped -gt 0) { Remove-OP2LastEntry $Projection[$key] $dropped; $omitted[$key] = $dropped }
        }
    }
    if ($omitted.Count) { $Projection['Omitted'] = $omitted }
    if ($null -eq $Settings['MaxOutputBytes']) { return $Projection }
    foreach ($key in $names) {
        while ($Projection[$key].Count -and (Measure-OP2Delivery $Projection $Settings) -gt $Settings['MaxOutputBytes']) {
            Remove-OP2LastEntry $Projection[$key] 1
            $omitted[$key] = 1 + [int]$omitted[$key]
            $Projection['Omitted'] = $omitted
        }
    }
    return $Projection
}
