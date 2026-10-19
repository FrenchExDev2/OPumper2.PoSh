$script:OP2ShadowSql = @'
SELECT r.id AS Recall, COALESCE(r.route, r.label) AS Command, r.timestamp AS Timestamp, i.tokens AS SourceTokens,
(SELECT d.tokens FROM deliveries d JOIN delivery_invocations x ON x.delivery=d.id WHERE x.invocation=r.invocation ORDER BY d.timestamp LIMIT 1) AS DeliveredTokens
FROM recalls r LEFT JOIN invocations i ON i.id=r.invocation
WHERE (@since IS NULL OR r.timestamp >= @since) AND (@command IS NULL OR r.route=@command OR r.label=@command)
ORDER BY r.timestamp;
'@

function Measure-OPumper2Contract {
    # Shadow measurement: replays a candidate contract over recalled outputs and compares what it would deliver with
    # what was delivered, without delivering anything. Contract returns a fresh contract for each output, with State,
    # OnBatch or OnRecord, Complete and optionally Projection, such as { New-DotnetBuildContract }.
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Contract, [string[]]$Recall, [string]$Command, [Nullable[datetime]]$Since,
        [ValidateSet('json','yaml')][string]$Format, [string]$DatabasePath, [switch]$AsObject, [switch]$AsJson, [switch]$AsYaml, [switch]$AsText)
    $configuration = Get-OP2Configuration
    if ($DatabasePath) { $configuration.DatabasePath = @(Resolve-OP2DatabasePath $DatabasePath $configuration)[0] }
    $output = Get-OP2Format $PSBoundParameters $configuration
    $delivery = $(if ($Format) { $Format } elseif ($configuration.OutputFormat -eq 'json') { 'json' } else { 'yaml' })
    $rows = @(Invoke-OP2Sql -Configuration $configuration -Read -Sql $script:OP2ShadowSql -Parameters @{
        since = $(if ($null -ne $Since) { ([datetime]$Since).ToUniversalTime().ToString('O') } else { $null }); command = $(if ($Command) { $Command } else { $null }) })
    if ($Recall) { $rows = @($rows | Where-Object { $_.Recall -in $Recall }) }
    $entries = foreach ($row in $rows) {
        $candidate = & $Contract
        $callback = Get-OP2ContractCallback $candidate
        $replayed = Invoke-OP2Replay (Read-OP2Recall $row.Recall $configuration) (New-OP2ReplayCall @callback -State $candidate.State -Complete $candidate.Complete)
        $result = $(if ($candidate.PSObject.Properties['Projection'] -and $candidate.Projection) { New-OPumper2Result -Completion $replayed -Projection $candidate.Projection } else { $replayed })
        $text = (Format-OP2Delivery @($result) $delivery $configuration.MaxItems $configuration.MaxOutputBytes $configuration.ExcerptLines $configuration).Text
        $shadow = Get-OP2OptionalTokenCount $text $configuration
        [pscustomobject][ordered]@{ Recall = $row.Recall; Command = $row.Command; Timestamp = $row.Timestamp; SourceTokens = $row.SourceTokens
            DeliveredTokens = $row.DeliveredTokens; ShadowTokens = $shadow
            Difference = $(if ($null -ne $row.DeliveredTokens -and $null -ne $shadow) { $row.DeliveredTokens - $shadow } else { $null }) }
    }
    $compared = @($entries | Where-Object { $null -ne $_.Difference -and $null -ne $_.SourceTokens })
    $source = 0L; $delivered = 0L; $shadowed = 0L
    foreach ($entry in $compared) { $source += $entry.SourceTokens; $delivered += $entry.DeliveredTokens; $shadowed += $entry.ShadowTokens }
    $data = [ordered]@{ Outputs = @($entries).Count; Compared = $compared.Count; SourceTokens = $source; DeliveredTokens = $delivered; ShadowTokens = $shadowed
        SavedVsDelivered = $delivered - $shadowed; ShadowRate = $(if ($source) { ($source - $shadowed) / $source } else { $null }); Entries = @($entries) }
    $result = New-OP2Completion -Data $data
    # Shadow reports are not measured either.
    if ($output -eq 'object') { return $result }
    if ($output -eq 'text') {
        return "Shadow contract over $($data.Compared) of $($data.Outputs) recalled outputs: $(Format-OP2GainCount $data.ShadowTokens) tokens instead of $(Format-OP2GainCount $data.DeliveredTokens) delivered ($(Format-OP2GainCount $data.SavedVsDelivered) saved), $(Format-OP2GainRate $data.ShadowRate) of the captured tokens saved.`n`n" + (Format-OP2Table $data.Entries)
    }
    Format-OPumper2Report $result $PSBoundParameters
}
