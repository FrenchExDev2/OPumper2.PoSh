function Enter-OP2Call {
    # The current pointer is the public API boundary of this runspace. All call state belongs to an explicit scope;
    # nested calls share their outer account, while their options and task membership have their own lifetime.
    param([long]$Entered)
    $parent = $script:OP2CurrentCall
    $account = $(if ($parent) { $parent.Account } else {
        [pscustomobject]@{ PendingEntered = $Entered; StorageWrites = [Collections.Generic.List[object]]::new()
            Stores = [Collections.Generic.Dictionary[string,object]]::new($script:OP2PathComparer) }
    })
    $scope = [pscustomobject]@{ Parent = $parent; Entered = $Entered; Account = $account; Configuration = $null
        Environment = $script:OP2Environment; Task = $null }
    $script:OP2CurrentCall = $scope
    return $scope
}

function Exit-OP2Call {
    param([object]$Context = $script:OP2CurrentCall)
    try {
        if (!$Context.Parent) { foreach ($store in @($Context.Account.Stores.Values)) { Close-OP2Store $store } }
    } finally { $script:OP2CurrentCall = $Context.Parent }
}

function Get-OP2CallConfiguration {
    param([object]$Context = $script:OP2CurrentCall)
    if (!$Context) { return Get-OP2Configuration }
    if ($null -eq $Context.Configuration) {
        if ($Context.Parent -and [object]::ReferenceEquals($Context.Environment, $Context.Parent.Environment)) {
            $Context.Configuration = Get-OP2CallConfiguration $Context.Parent
        } else { $Context.Configuration = Get-OP2Configuration }
    }
    return $Context.Configuration
}

function Get-OP2CallTask {
    param([object]$Context = $script:OP2CurrentCall)
    for ($scope = $Context; $null -ne $scope; $scope = $scope.Parent) { if ($null -ne $scope.Task) { ,$scope.Task } }
}

function Add-OP2StorageWrite {
    param([long]$Start, [object]$Context = $script:OP2CurrentCall)
    $write = [pscustomobject]@{ At = $Start; Ms = Get-OP2Duration $Start (Get-OP2Timestamp) }
    if ($Context) { $Context.Account.StorageWrites.Add($write) }
}

function Get-OP2StorageDuration {
    param([Nullable[long]]$Since, [object]$Context = $script:OP2CurrentCall)
    $sum = 0.0
    if ($Context) { foreach ($write in $Context.Account.StorageWrites) { if ($null -eq $Since -or $write.At -ge $Since) { $sum += $write.Ms } } }
    return $sum
}

function Get-OP2UtcNow {
    # UTC history timestamps and the monotonic duration clock have separate test boundaries.
    return [DateTime]::UtcNow
}
