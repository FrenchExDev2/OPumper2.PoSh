function Register-OPumper2 {
    # Registers a route. Registering the same Id, route and provider again has no effect, so a contributor may register
    # twice. A route already taken goes to the higher Priority: an equal or lower one is refused, like any other
    # duplicate route or identifier.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string[]]$Route,
        [Parameter(Mandatory)][scriptblock]$Handler, [string]$ProviderId = 'local', [int]$Priority = 0)
    if (!$Route.Count -or @($Route | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) { throw 'Route tokens must not be empty.' }
    # Routes are keyed by their joined tokens, compared without case like PowerShell's -eq.
    $key = $Route -join "`0"
    $same = @(Get-OP2RouteById $Id)
    if ($same.Count) {
        if (($same[0].Route -join "`0") -eq $key -and $same[0].ProviderId -eq $ProviderId) { return ConvertTo-OP2Registration $same[0] }
        throw 'Duplicate route or identifier.'
    }
    $taken = $script:OP2Routes[$key]
    if ($taken -and $taken.Priority -ge $Priority) { throw 'Duplicate route or identifier.' }
    $script:OP2Routes[$key] = [pscustomobject]@{ Id = $Id; Route = $Route; Handler = $Handler; ProviderId = $ProviderId; Priority = $Priority }
    $registration = ConvertTo-OP2Registration $script:OP2Routes[$key]
    # The registration names the route it took over, if any.
    if ($taken) { $registration | Add-Member -NotePropertyName Replaced -NotePropertyValue $taken.Id }
    $registration
}

function ConvertTo-OP2Registration {
    param([object]$Entry)
    [pscustomobject]@{ Id = $Entry.Id; Route = $Entry.Route; ProviderId = $Entry.ProviderId; Priority = $Entry.Priority }
}

function Get-OP2RoutePriority {
    # The priority of the route registered under exactly these tokens, or nothing when none is.
    param([string[]]$Route)
    $entry = $script:OP2Routes[$Route -join "`0"]
    if ($entry) { return $entry.Priority }
    return $null
}

function Get-OP2RouteById {
    param([string]$Id)
    foreach ($entry in $script:OP2Routes.Values) { if ($entry.Id -eq $Id) { $entry } }
}

function Unregister-OPumper2 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $route = @(Get-OP2RouteById $Id)
    foreach ($entry in $route) { [void]$script:OP2Routes.Remove($entry.Route -join "`0") }
    return ($route.Count -gt 0)
}

function Find-OP2Route {
    # The longest registered prefix of the command line: one lookup per prefix length, longest first.
    param([string]$Command, [string[]]$ArgumentList)
    $tokens = [string[]](@($Command) + $ArgumentList)
    for ($length = $tokens.Count; $length; $length--) {
        $key = [string]::Join("`0", $tokens, 0, $length)
        if ($script:OP2Routes.ContainsKey($key)) { return $script:OP2Routes[$key] }
    }
    return $null
}

function Resolve-OPumper2Command {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][string]$Command,
        [Parameter(Position=1,ValueFromRemainingArguments)][string[]]$ArgumentList = @())
    $route = Find-OP2Route $Command $ArgumentList
    [pscustomobject]@{ Supported = ($null -ne $route); Id = $(if ($route) { $route.Id } else { $null });
        ProviderId = $(if ($route) { $route.ProviderId } else { $null }); Route = $(if ($route) { $route.Route } else { @() })
        Priority = $(if ($route) { $route.Priority } else { $null }) }
}
