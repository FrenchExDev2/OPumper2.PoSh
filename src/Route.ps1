function Get-OP2ContractCallback {
    # The callback of a contract, as parameters to splat: its OnBatch when it declares one, otherwise its OnRecord.
    param([object]$Contract)
    if ($Contract.PSObject.Properties['OnBatch'] -and $Contract.OnBatch) { return @{ OnBatch = $Contract.OnBatch } }
    return @{ OnRecord = $Contract.OnRecord }
}

function Invoke-OPumper2Route {
    # Runs a route's contract with the call's execution settings and returns its Result. The contract holds
    # ArgumentList, Environment, State, OnBatch or OnRecord, Complete, Projection and optionally SuccessExitCodes; its environment
    # applies over the caller's. A failure its Explained test accepts already holds its explanation in Data, so the
    # delivery carries no excerpt.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Call, [Parameter(Mandatory)][object]$Contract, [scriptblock]$Explained)
    $environment = @{}
    foreach ($key in $Call.Environment.Keys) { $environment[$key] = $Call.Environment[$key] }
    foreach ($key in $Contract.Environment.Keys) { $environment[$key] = $Contract.Environment[$key] }
    $options = Get-OP2ContractCallback $Contract
    if ($null -ne $Call.InputText) { $options.InputText = $Call.InputText }
    $success = $(if ($Contract.PSObject.Properties['SuccessExitCodes']) { $Contract.SuccessExitCodes } else { $Call.SuccessExitCodes })
    $native = Pump-Me $Call.Command -ArgumentList $Contract.ArgumentList -State $Contract.State -Complete $Contract.Complete `
        -WorkingDirectory $Call.WorkingDirectory -Environment $environment -Encoding $Call.Encoding -SuccessExitCodes $success `
        -TimeoutSeconds $Call.TimeoutSeconds -CancellationToken $Call.CancellationToken -MaxRecordCharacters $Call.MaxRecordCharacters -AsObject @options
    $result = @{ Completion = $native; Projection = $Contract.Projection }
    if ($Explained -and (& $Explained $native.Data)) { $result.ExcerptLines = 0 }
    New-OPumper2Result @result
}
