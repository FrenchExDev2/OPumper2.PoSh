function New-OP2DeliveryView {
    # The delivered text of values ending with a completion, within the presentation limits, without side effects:
    # records first, then Data, then excerpt lines give way to the byte budget.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs an in-memory delivery view without external side effects.')]
    param([object[]]$InputObject, [string]$Format, [int]$MaxItems, [int]$MaxOutputBytes, [int]$ExcerptLines, [hashtable]$Configuration, [string]$Recall)
    $compact = ($Configuration.Envelope -eq 'compact')
    $completion = $InputObject[-1]
    $presentation = $completion.PSObject.Properties['Presentation']
    if ($presentation) { $presentation = $presentation.Value }
    # A result's own excerpt window can only narrow the delivery's.
    if ($presentation -and $null -ne $presentation.ExcerptLines) { $ExcerptLines = [Math]::Min($ExcerptLines, $presentation.ExcerptLines) }
    $limits = New-OP2Limit $ExcerptLines
    # Only delivered records are protected; omitted ones are counted, never transformed.
    $kept = [Collections.Generic.List[object]]::new()
    foreach ($item in @($InputObject | Select-Object -SkipLast 1 | Select-Object -First $MaxItems)) {
        $kept.Add((Protect-OP2Value $item 1 $limits -Path "[$($kept.Count)]"))
    }
    # The delivered view is a copy: the local object keeps its complete domain value and gains no recall hint.
    $view = $completion.PSObject.Copy()
    if ($Recall) { $view | Add-Member -NotePropertyName Recall -NotePropertyValue $Recall -Force }
    $projectionFailed = $false
    if ($presentation -and $presentation.Projection) {
        $settings = @{ Format = $Format; MaxItems = $MaxItems; MaxOutputBytes = $MaxOutputBytes; ExcerptLines = $ExcerptLines
            Envelope = $view.PSObject.Copy(); Compact = $compact }
        try { $view.Data = Invoke-OP2DomainCallback $presentation.Projection @($completion.Data, $settings) }
        catch { $view.Data = $null; $projectionFailed = $true }
    }
    $final = Protect-OP2Envelope $view $limits
    if ($projectionFailed) { Add-OP2Truncation $final 'ProjectionFailed' }
    if ($limits.DepthApplied) { Add-OP2Truncation $final 'DepthLimit' }
    if ($limits.ObfuscationFailed) { Add-OP2Truncation $final 'ObfuscationFailed' }
    if ($limits.ExcerptApplied) { Add-OP2Truncation $final 'ExcerptLimit' }
    $omitted = $InputObject.Count - 1 - $kept.Count
    if ($omitted -gt 0) { Add-OP2Truncation $final 'ItemLimit' $omitted }
    $kept.Add($final)
    [pscustomobject]@{ Completion = $completion; Final = $final; Kept = $kept; Format = $Format; Compact = $compact
        MaxOutputBytes = $MaxOutputBytes; Text = $null; Document = $null; ByteCount = 0 }
}

function Format-OP2Delivery {
    param([object[]]$InputObject, [string]$Format, [int]$MaxItems, [int]$MaxOutputBytes, [int]$ExcerptLines, [hashtable]$Configuration, [string]$Recall)
    $delivery = New-OP2DeliveryView @PSBoundParameters
    Update-OP2DeliveryText $delivery
    Compress-OP2DeliveryRecord $delivery
    Compress-OP2DeliveryData $delivery
    Compress-OP2DeliveryExcerpt $delivery
    Compress-OP2DeliveryEnvelope $delivery
    if ($delivery.ByteCount -gt $MaxOutputBytes) { throw 'The output budget cannot contain the completion.' }
    return $delivery
}
