$script:OP2GraphDays = 30

# -GroupBy keys: each reads one delivery row. A new key appends one entry and its name to the ValidateSet.
$script:OP2GainKeys = [ordered]@{
    # The route of a routed delivery, otherwise the executable.
    Command = { param($row) if ($row.Route) { $row.Route } else { $row.Label } }
    Route = { param($row) $row.Route }
    Provider = { param($row) $row.Provider }
    Format = { param($row) $row.Format }
    Outcome = { param($row) $row.Outcome }
    Session = { param($row) $row.Session }
    Project = { param($row) $row.Project }
    # Periods follow the local calendar; weeks are ISO weeks.
    Day = { param($row) (ConvertTo-OP2LocalTime $row.Timestamp).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    Week = { param($row) $moment = ConvertTo-OP2LocalTime $row.Timestamp; '{0}-W{1:00}' -f [Globalization.ISOWeek]::GetYear($moment), [Globalization.ISOWeek]::GetWeekOfYear($moment) }
    Month = { param($row) (ConvertTo-OP2LocalTime $row.Timestamp).ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture) }
}

function ConvertTo-OP2LocalTime {
    param([string]$Timestamp)
    return [DateTimeOffset]::Parse($Timestamp, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime().DateTime
}

function Test-OP2TokenPair {
    # Token comparisons need every source count and the delivered count.
    param([object]$Row)
    return ($Row.UnknownTokens -eq 0 -and $null -ne $Row.OutputTokens)
}

function Get-OP2GainKey {
    param([object]$Row, [string[]]$By)
    $values = foreach ($name in $By) {
        $value = & $script:OP2GainKeys[$name] $Row
        if ($value) { $value } else { '(none)' }
    }
    return @($values) -join ' | '
}

function Measure-OP2Gain {
    # Weighted totals: volumes, tokens of complete pairs, recalls, lossy deliveries, delivered composition and the
    # alternate format. Rates divide totals; they are not means of individual rates.
    param([object[]]$Rows)
    $source = 0L; $output = 0L; $sourceTokens = 0L; $outputTokens = 0L; $pairs = 0L; $reruns = 0L; $lossy = 0L; $elapsed = 0.0; $stored = 0L; $recalled = 0L
    $layered = 0L; $layerOutput = 0L; $data = 0L; $records = 0L; $excerpt = 0L
    $alternated = 0L; $delivered = 0L; $alternate = 0L; $alternateFormats = [Collections.Generic.SortedSet[string]]::new()
    foreach ($row in $Rows) {
        $source += $row.SourceBytes; $output += $row.OutputBytes; $elapsed += $row.ElapsedMs
        if ($row.Rerun) { $reruns++ }
        if ($row.RecallId) { $stored++ }
        if ($row.RecallReads) { $recalled++ }
        if ($row.Truncation) { $lossy++ }
        if (!(Test-OP2TokenPair $row)) { continue }
        $sourceTokens += $row.SourceTokens; $outputTokens += $row.OutputTokens; $pairs++
        if ($null -ne $row.DataTokens) { $layered++; $layerOutput += $row.OutputTokens; $data += $row.DataTokens; $records += $row.RecordTokens; $excerpt += $row.ExcerptTokens }
        if ($null -ne $row.AlternateTokens) { $alternated++; $delivered += $row.OutputTokens; $alternate += $row.AlternateTokens; [void]$alternateFormats.Add($row.AlternateFormat) }
    }
    $count = $Rows.Count
    [ordered]@{ Compared = $count; TokenCompared = $pairs; SourceBytes = $source; OutputBytes = $output; SavedBytes = $source - $output
        Rate = $(if ($source) { ($source - $output) / $source } else { $null })
        SourceTokens = $(if ($pairs) { $sourceTokens } else { $null }); OutputTokens = $(if ($pairs) { $outputTokens } else { $null })
        SavedTokens = $(if ($pairs) { $sourceTokens - $outputTokens } else { $null })
        TokenRate = $(if ($sourceTokens) { ($sourceTokens - $outputTokens) / $sourceTokens } else { $null })
        Reruns = $reruns; RerunRate = $(if ($count) { $reruns / $count } else { $null })
        # Recall store: outputs kept for these deliveries, and those read back (rtk gain --recalls).
        Stored = $stored; Recalled = $recalled; RecallRate = $(if ($stored) { $recalled / $stored } else { $null })
        Lossy = $lossy; LossyRate = $(if ($count) { $lossy / $count } else { $null }); ElapsedMs = $elapsed
        # The envelope is what the delivered text holds besides Data, records and the excerpt.
        Layers = $(if ($layered) { [ordered]@{ Envelope = $layerOutput - $data - $records - $excerpt; Data = $data; Records = $records; Excerpt = $excerpt } } else { $null })
        # Mixed YAML and JSON deliveries have both alternates: json/yaml.
        Alternate = $(if ($delivered) { [ordered]@{ Format = @($alternateFormats) -join '/'; Compared = $alternated; Delivered = $delivered; Tokens = $alternate; Rate = ($delivered - $alternate) / $delivered } } else { $null }) }
}

function Add-OP2GainRerun {
    # A rerun is a delivery whose command line was already delivered within the window: the first one did not suffice.
    # Rows carry a Rerun property, which is set in place.
    param([object[]]$Rows, [int]$WindowMinutes)
    $previous = @{}
    foreach ($row in $Rows) {
        $rerun = $false
        if ($row.Fingerprint) {
            $moment = [DateTimeOffset]::Parse($row.Timestamp, [Globalization.CultureInfo]::InvariantCulture)
            # Fingerprints are salted per database.
            $key = "$($row.Database)`0$($row.Fingerprint)"
            $rerun = ($previous.ContainsKey($key) -and ($moment - $previous[$key]).TotalMinutes -le $WindowMinutes)
            $previous[$key] = $moment
        }
        $row.Rerun = $rerun
    }
}

function Get-OP2GainGroup {
    # One pass over the rows; keys compare without case and keep their first spelling, like Group-Object.
    param([object[]]$Rows, [string[]]$By)
    $buckets = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $Rows) {
        $key = Get-OP2GainKey $row $By
        if (!$buckets.ContainsKey($key)) { $buckets[$key] = [pscustomobject]@{ Name = $key; Group = [Collections.Generic.List[object]]::new() } }
        $buckets[$key].Group.Add($row)
    }
    $groups = @(foreach ($group in $buckets.Values) {
        $entry = [ordered]@{ Key = $group.Name }
        $measure = Measure-OP2Gain $group.Group.ToArray()
        foreach ($name in $measure.Keys) { $entry[$name] = $measure[$name] }
        [pscustomobject]$entry
    })
    # Commands that save the most come first; other keys sort by name, so periods are chronological.
    if ($By[0] -eq 'Command') { return @($groups | Sort-Object @{ Expression = 'SavedBytes'; Descending = $true }, Key) }
    return @($groups | Sort-Object Key)
}

function ConvertTo-OP2GainEntry {
    param([object]$Row)
    $measure = Measure-OP2Gain @($Row)
    [pscustomobject][ordered]@{ Timestamp = $Row.Timestamp; Command = & $script:OP2GainKeys.Command $Row; Format = $Row.Format; Outcome = $Row.Outcome
        Rerun = [bool]$Row.Rerun; Recall = $Row.RecallId; Compared = ($Row.Complete -eq 1); Truncation = $Row.Truncation
        SourceTokens = $measure.SourceTokens; OutputTokens = $measure.OutputTokens; SavedTokens = $measure.SavedTokens; TokenRate = $measure.TokenRate
        SourceBytes = $measure.SourceBytes; OutputBytes = $measure.OutputBytes }
}

function Select-OP2GainEntry {
    # The largest savings (descending) or losses (ascending) among deliveries with known tokens.
    param([object[]]$Rows, [int]$Count, [switch]$Descending)
    $ranked = @($Rows | Where-Object { Test-OP2TokenPair $_ } |
        Sort-Object @{ Expression = { $_.SourceTokens - $_.OutputTokens }; Descending = $Descending.IsPresent } | Select-Object -First $Count)
    return @($ranked | ForEach-Object { ConvertTo-OP2GainEntry $_ })
}

function Get-OP2GainGraph {
    # Saved tokens per local day over the last days, today included; a day without deliveries saved nothing.
    param([object[]]$Rows, [datetime]$Today = [datetime]::Today)
    $days = [ordered]@{}
    for ($offset = $script:OP2GraphDays - 1; $offset -ge 0; $offset--) {
        $days[$Today.AddDays(-$offset).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)] = 0L
    }
    foreach ($row in @($Rows | Where-Object { Test-OP2TokenPair $_ })) {
        $day = & $script:OP2GainKeys.Day $row
        if ($days.Contains($day)) { $days[$day] += $row.SourceTokens - $row.OutputTokens }
    }
    return @($days.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Day = $_.Key; SavedTokens = $_.Value } })
}

function Get-OP2GainCost {
    # Valuation at the configured price per million tokens, or nothing without a price.
    param([object]$Measure, [hashtable]$Configuration)
    if ($null -eq $Configuration.TokenPrice) { return $null }
    $price = [double]$Configuration.TokenPrice
    [ordered]@{ Currency = $Configuration.Currency; TokenPrice = $Configuration.TokenPrice
        Captured = $Measure.SourceTokens * $price / 1e6; Delivered = $Measure.OutputTokens * $price / 1e6; Saved = $Measure.SavedTokens * $price / 1e6 }
}

function Get-OP2GainQuota {
    # Saved tokens of the current local month against the configured monthly budget, or nothing without a budget.
    param([object[]]$Rows, [hashtable]$Configuration, [datetime]$Today = [datetime]::Today, [string]$Tier)
    # A named tier (quotaTiers, or quotaTier by default) takes precedence over monthlyTokenBudget.
    if (!$Tier) { $Tier = $Configuration.QuotaTier }
    $budget = $Configuration.MonthlyTokenBudget
    if ($Tier) {
        if (!$Configuration.QuotaTiers.Contains($Tier)) { throw "Unknown quota tier: $Tier." }
        $budget = $Configuration.QuotaTiers[$Tier]
    }
    if (!$budget) { return $null }
    $month = $Today.ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture)
    $saved = (Measure-OP2Gain @($Rows | Where-Object { (& $script:OP2GainKeys.Month $_) -eq $month })).SavedTokens
    [ordered]@{ Month = $month; Tier = $(if ($Tier) { $Tier } else { $null }); Budget = $budget; SavedTokens = $saved
        Share = $(if ($null -ne $saved) { $saved / $budget } else { $null }) }
}
