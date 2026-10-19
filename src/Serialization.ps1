
function Compress-OP2Envelope {
    # Delivered engine metadata omits defaults; Data, a domain value, is never compacted.
    param([object]$Value)
    if ($Value -is [Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($name in @($Value.get_Keys())) {
            $item = $Value[$name]
            if ($name -ne 'Data') { $item = Compress-OP2Envelope $item }
            if (!(Test-OP2DefaultValue $name $item)) { $map[$name] = $item }
        }
        return ,$map
    }
    if ($Value -is [Collections.IList]) { return ,@(foreach ($item in $Value) { Compress-OP2Envelope $item }) }
    return $Value
}

function Test-OP2DefaultValue {
    # Absent means null, false, zero, empty, or true for completeness flags. A known exit code and non-null
    # Data always remain.
    param([string]$Name, [object]$Value)
    if ($null -eq $Value) { return $true }
    if ($Name -in @('Data','ExitCode')) { return $false }
    if ($Value -is [bool]) { return $Value -eq ($Name -in @('Source','Analysis','Complete')) }
    # A measurement that never happened (NotDelivered, its initial status) is a default as well.
    if ($Value -is [string]) { return !$Value.Length -or ($Name -eq 'Status' -and $Value -eq 'NotDelivered') }
    if ($Value -is [Collections.ICollection]) { return !$Value.Count }
    return $Value -is [ValueType] -and $Value -eq 0
}

function ConvertTo-OP2Document {
    param([object]$Value, [string]$Format)
    if ($Format -eq 'json') { return ConvertTo-Json -InputObject $Value -Depth 40 -Compress }
    # Like ConvertTo-Yaml, nothing is written for nothing.
    if ($null -eq $Value) { return $null }
    $writer = [IO.StringWriter]::new()
    (Get-OP2YamlSerializer).Serialize($writer, $Value)
    return $writer.ToString()
}

# What a compact envelope keeps: the outcome and what explains it.
$script:OP2CompactKeys = @('Kind','Outcome','Data','Execution','Error','Excerpt','Truncation','Recall')
$script:OP2CompactExecution = @('ExitCode','Issues')

function Select-OP2CompactEnvelope {
    param([Collections.IDictionary]$Envelope)
    $map = [ordered]@{}
    foreach ($name in $Envelope.Keys) { if ($name -in $script:OP2CompactKeys) { $map[$name] = $Envelope[$name] } }
    if ($map.Contains('Execution')) {
        $execution = [ordered]@{}
        foreach ($name in $map.Execution.Keys) { if ($name -in $script:OP2CompactExecution) { $execution[$name] = $map.Execution[$name] } }
        $map.Execution = $execution
        if (!$execution.Count) { $map.Remove('Execution') }
    }
    return $map
}

function ConvertTo-OP2Text {
    param([object[]]$Values, [string]$Format, [switch]$Compact)
    # The completion closes every delivery; only its metadata is compacted.
    $Values[-1] = Compress-OP2Envelope $Values[-1]
    if ($Compact) { $Values[-1] = Select-OP2CompactEnvelope $Values[-1] }
    return ConvertTo-OP2Document $Values $Format
}

function Get-OP2DeliveryPart {
    # The texts the delivery is made of, measured with it: Data, records and excerpt in the delivered format, and the
    # whole delivery in the alternate format when configured. The envelope is the remainder.
    param([object[]]$Document, [string]$Format, [hashtable]$Configuration)
    $completion = $Document[-1]
    $parts = @{ Data = ''; Records = ''; Excerpt = '' }
    if ($completion.Contains('Data')) { $parts.Data = ConvertTo-OP2Document $completion.Data $Format }
    if ($Document.Count -gt 1) { $parts.Records = ConvertTo-OP2Document @($Document | Select-Object -SkipLast 1) $Format }
    if ($completion.Contains('Excerpt')) { $parts.Excerpt = ConvertTo-OP2Document $completion.Excerpt $Format }
    if ($Configuration.MeasureAlternateFormat) {
        $parts.AlternateFormat = $(if ($Format -eq 'json') { 'yaml' } else { 'json' })
        $parts.Alternate = ConvertTo-OP2Text $Document $parts.AlternateFormat -Compact:($Configuration.Envelope -eq 'compact')
    }
    return $parts
}



function ConvertTo-OPumper2Output {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$InputObject,
        [ValidateSet('json','yaml','object')][string]$Format = 'yaml',
        [ValidateRange(0,[int]::MaxValue)][Nullable[int]]$MaxItems,
        [ValidateRange(256,[int]::MaxValue)][Nullable[int]]$MaxOutputBytes,
        [ValidateRange(0,[int]::MaxValue)][Nullable[int]]$ExcerptLines,
        [hashtable]$Configuration,
        # Recorded with the delivery measurement: Route, Provider and Command (stored only as a fingerprint).
        [hashtable]$Origin = @{})
    if ($Format -eq 'object') { foreach ($item in $InputObject) { $PSCmdlet.WriteObject($item, $false) }; return }
    if (!$InputObject.Count -or $InputObject[-1].Kind -ne 'Completion') { throw 'A completion object must end the output.' }
    $owned = $null
    if (!$script:OP2CurrentCall) { $owned = Enter-OP2Call $Origin['Entered'] }
    try {
    $options = Resolve-OP2CallOption $PSBoundParameters -Configuration $Configuration -Format $Format
    $Configuration = $options.Configuration
    $MaxItems = $options.MaxItems; $MaxOutputBytes = $options.MaxOutputBytes; $ExcerptLines = $options.ExcerptLines
    # The recall store keeps the complete output first, so the delivery can name it.
    # The total runs from the entry into pump (Origin.Entered) up to the stored delivery.
    $recall = $null; $timing = @{ Entered = $Origin['Entered'] }
    $recalling = Get-OP2Timestamp; $stored = Get-OP2StorageDuration
    if (!@(Get-OP2CallTask).Count) { $recall = Save-OP2Recall $InputObject[-1] $Configuration $Origin }
    # Masking and compressing the recall; its write belongs to the storage phase.
    $timing.RecallMs = (Get-OP2Duration $recalling (Get-OP2Timestamp)) - ((Get-OP2StorageDuration) - $stored)
    $formatting = Get-OP2Timestamp
    $delivery = Format-OP2Delivery $InputObject $Format $MaxItems $MaxOutputBytes $ExcerptLines $Configuration $recall
    $timing.FormatMs = Get-OP2Duration $formatting (Get-OP2Timestamp)
    if (!@(Get-OP2CallTask).Count) {
        $parts = Get-OP2DeliveryPart $delivery.Document $Format $Configuration
        Save-OP2Delivery -Completion $delivery.Completion -Text $delivery.Text -Configuration $Configuration -Origin $Origin -Format $Format `
            -Parts $parts -Truncation (@($delivery.Final.Truncation.Reasons) -join ',') -Timing $timing
    }
    return $delivery.Text
    } finally { if ($owned) { Exit-OP2Call $owned } }
}

function Out-OPumper2 {
    # The delivery of local values, the only output a script that kept a -AsObject result returns: values ending with
    # a completion are delivered as pump would have delivered them; any other values become the Data of a successful
    # result. Either way the text is bounded, obfuscated, measured and recalled, never the raw object with its capture.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(ValueFromPipeline)][AllowNull()][object]$InputObject,
        [switch]$AsJson, [switch]$AsYaml,
        [ValidateRange(0,[int]::MaxValue)][Nullable[int]]$MaxItems,
        [ValidateRange(256,[int]::MaxValue)][Nullable[int]]$MaxOutputBytes,
        [ValidateRange(0,[int]::MaxValue)][Nullable[int]]$ExcerptLines)
    begin { $values = [Collections.Generic.List[object]]::new() }
    process { $values.Add($InputObject) }
    end {
        $options = Resolve-OP2CallOption $PSBoundParameters
        $configuration = $options.Configuration
        $format = $options.Format
        # A text delivery is the point: an object output format falls back to YAML.
        if ($format -notin @('json','yaml')) { $format = 'yaml' }
        $last = $(if ($values.Count) { $values[$values.Count - 1] })
        if (!($last -and $last.PSObject.Properties['Kind'] -and $last.Kind -eq 'Completion')) {
            # The subexpression unrolls the array: one value is the Data itself, several an array, none nothing.
            $data = $(if ($values.Count) { $values.ToArray() })
            $values = @(New-OPumper2Result -Data $data)
        }
        $limits = @{ MaxItems = $options.MaxItems; MaxOutputBytes = $options.MaxOutputBytes; ExcerptLines = $options.ExcerptLines }
        ConvertTo-OPumper2Output -InputObject @($values) -Format $format -Configuration $configuration @limits
    }
}

function Format-OPumper2Report {
    # A report delivery: a completion in the format its caller's As* switches select (Bound), obfuscated, compacted
    # like any delivery and never measured or recalled. AsObject returns the completion itself.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$InputObject, [hashtable]$Bound = @{})
    $configuration = Get-OP2Configuration
    $format = Get-OP2Format $Bound $configuration
    if ($format -eq 'object') { return $InputObject }
    if ($format -notin @('json','yaml')) { throw "Unsupported report format: $format." }
    ConvertTo-OP2Text @((Protect-OP2Value $InputObject -Plain)) $format -Compact:($configuration.Envelope -eq 'compact')
}
