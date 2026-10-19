function Clear-OPumper2Measurement {
    # Removes deliveries older than Before (or all of them) and the invocations no remaining delivery needs, like the
    # automatic retention. Supports -WhatIf and asks for confirmation.
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Before')]
    param([Parameter(Mandatory, ParameterSetName = 'Before')][datetime]$Before,
        [Parameter(Mandatory, ParameterSetName = 'All')][switch]$All, [string]$DatabasePath)
    $configuration = Get-OP2Configuration
    $configuration.DatabasePath = @(Resolve-OP2DatabasePath $DatabasePath $configuration)[0]
    $cutoff = $(if ($All) { [DateTime]::MaxValue } else { $Before.ToUniversalTime() }).ToString('O')
    $result = [pscustomobject]@{ Database = $configuration.DatabasePath; Deliveries = 0L; Invocations = 0L; Removed = $false }
    if (!(Test-Path -LiteralPath $configuration.DatabasePath)) { return $result }
    $count = @(Invoke-OP2Sql -Configuration $configuration -Read -Parameters @{ cutoff = $cutoff } -Sql @'
SELECT (SELECT COUNT(*) FROM deliveries WHERE timestamp < @cutoff) AS Deliveries,
(SELECT COUNT(*) FROM invocations WHERE timestamp < @cutoff AND id NOT IN
 (SELECT x.invocation FROM delivery_invocations x JOIN deliveries d ON d.id=x.delivery WHERE d.timestamp >= @cutoff)) AS Invocations;
'@)[0]
    $result.Deliveries = $count.Deliveries; $result.Invocations = $count.Invocations
    if ($PSCmdlet.ShouldProcess($configuration.DatabasePath, "Remove $($count.Deliveries) deliveries and $($count.Invocations) invocations")) {
        Invoke-OP2Sql -Configuration $configuration -Parameters @{ cutoff = $cutoff } -Sql ('BEGIN;' + $script:OP2PurgeSql + 'COMMIT;')
        $result.Removed = $true
    }
    return $result
}
