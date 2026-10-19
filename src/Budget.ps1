function Get-OP2ExcerptTail {
    # Excerpt tails of a delivered completion and of its issues, in document order.
    param([Collections.IDictionary]$Completion)
    $owners = [Collections.Generic.List[object]]::new()
    $owners.Add($Completion)
    foreach ($issue in @($Completion['Execution']['Issues'])) { if ($null -ne $issue) { $owners.Add($issue) } }
    foreach ($owner in $owners) {
        $excerpt = $owner['Excerpt']
        if ($null -eq $excerpt) { continue }
        foreach ($name in @('Stdout','Stderr')) { if ($excerpt.Contains($name)) { ,$excerpt[$name].Tail } }
    }
}

function Update-OP2DeliveryText {
    # Every mutation invalidates the serialized size. This is the only place a budget stage refreshes it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Updates an in-memory delivery view without external side effects.')]
    param([object]$Delivery)
    $Delivery.Document = $Delivery.Kept.ToArray()
    $Delivery.Text = ConvertTo-OP2Text $Delivery.Document $Delivery.Format -Compact:$Delivery.Compact
    $Delivery.ByteCount = [Text.Encoding]::UTF8.GetByteCount($Delivery.Text)
}

function Compress-OP2DeliveryRecord {
    param([object]$Delivery)
    while ($Delivery.ByteCount -gt $Delivery.MaxOutputBytes -and $Delivery.Kept.Count -gt 1) {
        $Delivery.Kept.RemoveAt($Delivery.Kept.Count - 2)
        Add-OP2Truncation $Delivery.Final 'OutputLimit' 1
        Update-OP2DeliveryText $Delivery
    }
}

function Compress-OP2DeliveryData {
    param([object]$Delivery)
    if ($Delivery.ByteCount -gt $Delivery.MaxOutputBytes -and $null -ne $Delivery.Final.Data) {
        $Delivery.Final.Data = $null
        Add-OP2Truncation $Delivery.Final 'DataLimit'
        Update-OP2DeliveryText $Delivery
    }
}

function Compress-OP2DeliveryExcerpt {
    # Drop the oldest line of the longest tail first, the earliest tail on ties.
    param([object]$Delivery)
    $tails = @(Get-OP2ExcerptTail $Delivery.Final)
    while ($Delivery.ByteCount -gt $Delivery.MaxOutputBytes) {
        $longest = $null; $size = 0
        foreach ($tail in $tails) { if ($tail.Count -gt $size) { $longest = $tail; $size = $tail.Count } }
        if (!$size) { break }
        $longest.RemoveAt(0)
        Add-OP2Truncation $Delivery.Final 'ExcerptLimit'
        Update-OP2DeliveryText $Delivery
    }
}

function Compress-OP2DeliveryEnvelope {
    param([object]$Delivery)
    if ($Delivery.ByteCount -gt $Delivery.MaxOutputBytes) {
        $completion = $Delivery.Completion
        $Delivery.Final = @{ Kind = 'Completion'; Outcome = $completion.Outcome; Data = $null
            Execution = @{ ExitCode = $completion.Execution.ExitCode }; Completeness = $completion.Completeness
            Error = $(if ($completion.Error) { @{ Code = $completion.Error.Code } } else { $null })
            Truncation = @{ Applied = $true; Reasons = @('MetadataLimit') } }
        $Delivery.Kept.Clear(); $Delivery.Kept.Add($Delivery.Final)
        Update-OP2DeliveryText $Delivery
    }
}

