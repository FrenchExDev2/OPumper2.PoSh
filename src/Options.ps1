# Limits shared by configuration, execution and every delivery entry point. Zero is meaningful for items and excerpts.
$script:OP2LimitMinimum = [ordered]@{ MaxItems = 0; MaxOutputBytes = 256; ExcerptLines = 0; TimeoutSeconds = 1 }

function Resolve-OP2CallLimit {
    param([hashtable]$Bound = @{}, [hashtable]$Configuration)
    $limits = @{}
    foreach ($name in $script:OP2LimitMinimum.Keys) {
        $value = $(if ($Bound.ContainsKey($name)) { $Bound[$name] } else { $Configuration[$name] })
        if ($value -lt $script:OP2LimitMinimum[$name]) { throw 'Invalid execution or presentation limit.' }
        $limits[$name] = $value
    }
    return $limits
}

function Resolve-OP2CallOption {
    # Resolve once at the entry point; downstream operations receive this configuration instead of reading it again.
    param([hashtable]$Bound = @{}, [hashtable]$Configuration, [string]$Format)
    if (!$Configuration) { $Configuration = Get-OP2CallConfiguration }
    $options = Resolve-OP2CallLimit $Bound $Configuration
    $options.Configuration = $Configuration
    $options.Format = $(if ($PSBoundParameters.ContainsKey('Format')) { $Format } else { Get-OP2Format $Bound $Configuration })
    return $options
}
