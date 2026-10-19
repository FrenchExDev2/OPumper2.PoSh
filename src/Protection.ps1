function Protect-OP2Value {
    # -Plain skips the obfuscation pipe for engine metadata; nested Data and error messages re-enter it.
    param([object]$Value, [int]$Depth = 0, [hashtable]$Limits, [object]$Key, [string]$Path = '', [switch]$Plain)
    if ($Depth -gt 30) { if ($Limits) { $Limits.DepthApplied=$true }; return '[DEPTH LIMIT]' }
    if (!$Plain) { $Value = Invoke-OP2Obfuscation $Value @{ Key = $Key; Path = $Path; Depth = $Depth } $Limits }
    if ($null -eq $Value -or $Value -is [string]) { return $Value }
    $dictionary = $Value -is [Collections.IDictionary]
    # The Keys property itself: on a Hashtable, member access would return an entry named Keys.
    if ($dictionary) { $keys = @($Value.get_Keys()) }
    elseif ($Value -is [Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((Protect-OP2Value $item ($Depth + 1) $Limits -Path "$Path[$($items.Count)]" -Plain:$Plain)) }
        return ,$items.ToArray()
    }
    elseif ([Type]::GetTypeCode($Value.GetType()) -ne [TypeCode]::Object -or $Value -is [Guid] -or $Value -is [DateTimeOffset] -or $Value -is [TimeSpan] -or $Value -is [Numerics.BigInteger]) { return $Value }
    else { $keys = @($Value.PSObject.Properties | ForEach-Object Name) }
    $map = [ordered]@{}
    $prefix = $(if ($Path) { "$Path." } else { '' })
    foreach ($name in $keys) {
        # A dictionary entry is read by its key: member access would return the dictionary's own Keys, Values or
        # Count instead of the entries of those names.
        if ($dictionary) { $item = $Value[$name] } else { $item = $Value.$name }
        # A native capture on engine metadata stays on the local object; an unsuccessful delivery carries at most its
        # excerpt. The presentation of a result is applied, never delivered.
        if ($Plain -and $name -eq 'Capture') {
            if ($null -ne $item -and $Limits.ExcerptLines -gt 0 -and $Value.Outcome -ne 'Success') { $map['Excerpt'] = ConvertTo-OP2Excerpt $item $Limits "${prefix}Excerpt" }
            continue
        }
        # The presentation and the durations (Execution.Timing) stay on the local object.
        if ($Plain -and $name -in @('Presentation', 'Timing')) { continue }
        $map[$name] = Protect-OP2Value $item ($Depth + 1) $Limits -Key $name -Path "$prefix$name" -Plain:($Plain -and $name -notin @('Data','Message'))
    }
    return ,$map
}

function ConvertTo-OP2Excerpt {
    # The delivered view of a failure capture: the last lines of each stream, each cut to 1000 characters,
    # masked by the obfuscation pipe like domain text.
    param([object]$Capture, [hashtable]$Limits, [string]$Path)
    $excerpt = [ordered]@{}
    foreach ($name in @('Stdout','Stderr')) {
        $text = ([string]$Capture.$name).TrimEnd("`r", "`n")
        if (!$text) { continue }
        $lines = $text.Split("`n")
        $tail = [Collections.Generic.List[object]]::new()
        foreach ($line in @($lines | Select-Object -Last $Limits.ExcerptLines)) {
            $line = $line.TrimEnd("`r")
            if ($line.Length -gt 1000) { $line = $line.Substring(0, 1000) + [char]0x2026; $Limits.ExcerptApplied = $true }
            $tail.Add((Protect-OP2Value $line 0 $Limits -Key $name -Path "$Path.$($name)[$($tail.Count)]"))
        }
        $excerpt[$name] = [ordered]@{ Lines = $lines.Length; Tail = $tail }
    }
    $excerpt.Complete = $Capture.Complete
    $excerpt.Lossy = $Capture.Lossy
    return ,$excerpt
}
function New-OP2Limit {
    # The presentation limits one delivery shares across its records and envelope, and the flags they raise.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates an in-memory table without side effects.')]
    param([object]$ExcerptLines)
    @{ DepthApplied = $false; ObfuscationFailed = $false; ExcerptLines = $ExcerptLines; ExcerptApplied = $false }
}

function Protect-OP2Envelope {
    # A completion as delivered: obfuscated, bounded in depth and excerpt, its metadata plain.
    param([object]$View, [hashtable]$Limits)
    return Protect-OP2Value $View 1 $Limits -Plain
}
