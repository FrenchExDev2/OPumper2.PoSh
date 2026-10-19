function Test-OP2FilterExplained {
    # Kept lines of a failed command are its explanation; its raw excerpt would repeat them.
    param([object]$Report)
    if ($null -eq $Report) { return $false }
    return (!$Report.Succeeded -and [bool]$Report.Kept.Count)
}

function Invoke-OP2FilterRoute {
    param([hashtable]$Call, [object]$Definition, [int]$RouteLength)
    $contract = New-OPumper2FilterContract -Definition $Definition -ArgumentList $Call.ArgumentList -RouteLength $RouteLength -WorkingDirectory $Call.WorkingDirectory
    Invoke-OPumper2Route -Call $Call -Contract $contract -Explained (Get-Command Test-OP2FilterExplained -CommandType Function).ScriptBlock
}

function Register-OPumper2Filter {
    # Registers the routes of a catalogue folder (or of the given filters). A route already registered with the same
    # or a higher priority, such as git status or dotnet build, keeps its richer contract; a lower one gives way. The
    # first route of a filter takes its Id; the others take "Id (route)". Registering again has no effect.
    [CmdletBinding()]
    param([string[]]$Id, [Parameter(Mandatory)][string]$Path, [int]$Priority = 0)
    $invoke = Get-Command Invoke-OP2FilterRoute -CommandType Function
    foreach ($definition in @(Get-OPumper2Filter -Id $Id -Path $Path)) {
        $first = $true
        foreach ($route in $definition.Routes) {
            $tokens = @($route -split '\s+' | Where-Object { $_ })
            $name = $(if ($first) { $definition.Id } else { "$($definition.Id) ($route)" })
            $first = $false
            $taken = Get-OP2RoutePriority $tokens
            # Its own route, registered before, is registered again without effect.
            $own = @(Get-OP2RouteById $name | Where-Object { ($_.Route -join "`0") -eq ($tokens -join "`0") -and $_.ProviderId -eq 'filters' }).Count
            if ($null -ne $taken -and $taken -ge $Priority -and !$own) { continue }
            $length = $tokens.Count
            $filter = $definition
            $handler = { param($call) & $invoke $call $filter $length }.GetNewClosure()
            Register-OPumper2 -Id $name -Route $tokens -Handler $handler -ProviderId filters -Priority $Priority
        }
    }
}
