# The pumps section of the user's configuration: the contributor modules Import-OPumper2Workspace loads. Each entry has
# a unique name, exactly one of path (the module folder) and module (a name on the module path), enabled (true by
# default) and an optional integer priority: higher priorities register first and take their routes first.
$script:OP2PumpKeys = @('name', 'path', 'module', 'enabled', 'priority')
# Former contributor names and the modules that replaced them, for Repair-OPumper2Configuration.
$script:OP2PumpAliases = @{ Pnpm = 'Node'; Npm = 'Node'; Podman = 'Containers'; Docker = 'Containers'; Ripgrep = 'Search'; Build = 'Make' }

function Get-OP2ConfigurationPath {
    # OPUMPER2_CONFIG_PATH, or the user's file next to the measurement database.
    $path = Get-OP2EnvironmentValue 'OPUMPER2_CONFIG_PATH'
    if ($path) { return $path }
    return Join-Path $HOME '.opumper2/config.yaml'
}

function ConvertTo-OP2PumpEntry {
    # One entry of the pumps list, validated; errors name the entry.
    param([object]$Entry, [int]$Index)
    $where = "pumps[$Index]"
    if ($Entry -isnot [Collections.IDictionary]) { throw "$where must be a mapping." }
    foreach ($key in $Entry.get_Keys()) { if ($key -notin $script:OP2PumpKeys) { throw "$where`: unknown key '$key'." } }
    $name = $Entry['name']
    if (!$name) { throw "$where needs a name." }
    if ([bool]$Entry['path'] -eq [bool]$Entry['module']) { throw "$where ($name) needs exactly one of path and module." }
    $enabled = $(if ($Entry.Contains('enabled')) { $Entry['enabled'] } else { $true })
    if ($enabled -isnot [bool]) { throw "$where ($name): enabled must be true or false." }
    $priority = $Entry['priority']
    if ($null -ne $priority -and $priority -isnot [int]) { throw "$where ($name): priority must be an integer." }
    $exists = $(if ($Entry['path']) { Test-Path -LiteralPath $Entry['path'] -PathType Container } else { [bool](Get-Module -ListAvailable $Entry['module']) })
    [pscustomobject]@{ PSTypeName = 'OPumper2.Pump'; Name = [string]$name; Path = $Entry['path']; Module = $Entry['module']; Enabled = $enabled
        Priority = $(if ($null -ne $priority) { $priority } else { 0 }); Exists = $exists }
}

function Read-OP2PumpList {
    # The validated pumps of a configuration file, in file order; none without a file or a pumps section.
    param([string]$Path = (Get-OP2ConfigurationPath))
    if (!(Test-Path -LiteralPath $Path)) { return @() }
    # The whole file is validated first: its sections and general settings.
    [void](Get-OP2Configuration $Path)
    $entries = (Read-OP2ConfigurationDocument $Path)['pumps']
    if ($null -eq $entries) { return @() }
    if ($entries -isnot [Collections.IList]) { throw 'The pumps section must be a list.' }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pumps = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $pump = ConvertTo-OP2PumpEntry $entries[$index] $index
        if (!$names.Add($pump.Name)) { throw "pumps[$index]: duplicate name '$($pump.Name)'." }
        $pumps.Add($pump)
    }
    return $pumps.ToArray()
}

function Save-OP2PumpList {
    # Writes the pumps section, keeping the general settings. The YAML serializer writes values, not comments: a
    # rewritten file loses its comments.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Called by the public cmdlets once their ShouldProcess allowed the change.')]
    param([string]$Path, [object[]]$Pump)
    $document = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
        $general = (Read-OP2ConfigurationDocument $Path)['general']
        if ($null -ne $general) {
            $document.general = [ordered]@{}
            foreach ($key in @(@($general.get_Keys()) | Sort-Object)) { $document.general[$key] = $general[$key] }
        }
    }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($item in $Pump) {
        $entry = [ordered]@{ name = $item.Name }
        if ($item.Path) { $entry.path = $item.Path } else { $entry.module = $item.Module }
        $entry.enabled = $item.Enabled
        if ($item.Priority) { $entry.priority = $item.Priority }
        $entries.Add($entry)
    }
    $document.pumps = $entries.ToArray()
    [void][IO.Directory]::CreateDirectory((Split-Path $Path))
    [IO.File]::WriteAllText($Path, (ConvertTo-OP2Document $document 'yaml'), [Text.UTF8Encoding]::new($false))
}

function Find-OP2Pump {
    # The entry of a pump by name, or an error naming the file.
    param([object[]]$Pump, [string]$Name, [string]$Path)
    $found = @($Pump | Where-Object Name -eq $Name)
    if (!$found.Count) { throw "No pump named '$Name' in $Path." }
    return $found[0]
}

function Get-OPumper2Pump {
    # The pumps of the configuration, with whether each module can be found (Exists).
    [CmdletBinding()]
    [OutputType('OPumper2.Pump')]
    param([SupportsWildcards()][string]$Name = '*', [string]$ConfigurationPath = (Get-OP2ConfigurationPath))
    @(Read-OP2PumpList $ConfigurationPath) | Where-Object Name -like $Name
}

function Add-OPumper2Pump {
    # Adds a pump to the configuration; its name must be new.
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Path')]
    [OutputType('OPumper2.Pump')]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Module')][string]$Module, [switch]$Disabled, [int]$Priority,
        [string]$ConfigurationPath = (Get-OP2ConfigurationPath))
    $pumps = [Collections.Generic.List[object]]::new(@(Read-OP2PumpList $ConfigurationPath))
    if (@($pumps | Where-Object Name -eq $Name).Count) { throw "A pump named '$Name' already exists in $ConfigurationPath." }
    $location = $(if ($PSCmdlet.ParameterSetName -eq 'Path') { [IO.Path]::GetFullPath($Path) } else { $null })
    $entry = @{ name = $Name; enabled = !$Disabled }
    if ($location) { $entry.path = $location } else { $entry.module = $Module }
    if ($Priority) { $entry.priority = $Priority }
    $pump = ConvertTo-OP2PumpEntry $entry $pumps.Count
    if ($PSCmdlet.ShouldProcess($ConfigurationPath, "Add pump $Name")) {
        $pumps.Add($pump)
        Save-OP2PumpList $ConfigurationPath $pumps.ToArray()
    }
    $pump
}

function Remove-OPumper2Pump {
    # Removes a pump from the configuration.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [string]$ConfigurationPath = (Get-OP2ConfigurationPath))
    $pumps = @(Read-OP2PumpList $ConfigurationPath)
    [void](Find-OP2Pump $pumps $Name $ConfigurationPath)
    if ($PSCmdlet.ShouldProcess($ConfigurationPath, "Remove pump $Name")) { Save-OP2PumpList $ConfigurationPath @($pumps | Where-Object Name -ne $Name) }
}

function Set-OP2PumpState {
    # Enables or disables one pump, leaving the others as they are.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Called by Enable- and Disable-OPumper2Pump once their ShouldProcess allowed the change.')]
    param([string]$Name, [bool]$Enabled, [string]$ConfigurationPath)
    $pumps = @(Read-OP2PumpList $ConfigurationPath)
    (Find-OP2Pump $pumps $Name $ConfigurationPath).Enabled = $Enabled
    Save-OP2PumpList $ConfigurationPath $pumps
}

function Enable-OPumper2Pump {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [string]$ConfigurationPath = (Get-OP2ConfigurationPath))
    if ($PSCmdlet.ShouldProcess($ConfigurationPath, "Enable pump $Name")) { Set-OP2PumpState $Name $true $ConfigurationPath }
}

function Disable-OPumper2Pump {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [string]$ConfigurationPath = (Get-OP2ConfigurationPath))
    if ($PSCmdlet.ShouldProcess($ConfigurationPath, "Disable pump $Name")) { Set-OP2PumpState $Name $false $ConfigurationPath }
}

function New-OPumper2Configuration {
    # Creates the configuration file with the pump modules found next to the engine: dedicated contracts (modules with
    # code) first, then the catalogues, so dedicated routes win. An existing file is kept unless Force replaces it.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('OPumper2.Pump')]
    param([string]$Path = (Get-OP2ConfigurationPath), [switch]$Force, [string]$ModuleRoot = (Split-Path $script:OP2Root))
    if ((Test-Path -LiteralPath $Path) -and !$Force) { throw "$Path already exists; use -Force to replace it." }
    $found = @(Get-ChildItem -LiteralPath $ModuleRoot -Directory -Filter 'FrenchExDev.OPumper2.*.PoSh' | Where-Object { $_.Name -notlike 'FrenchExDev.OPumper2.Utility.*' })
    $ordered = @($found | Sort-Object @{ Expression = { !(Test-Path -LiteralPath (Join-Path $_.FullName 'src')) } }, Name)
    $pumps = @(for ($index = 0; $index -lt $ordered.Count; $index++) {
        $name = ($ordered[$index].Name -replace '^FrenchExDev\.OPumper2\.|\.PoSh$', '').ToLowerInvariant()
        ConvertTo-OP2PumpEntry @{ name = $name; path = $ordered[$index].FullName; enabled = $true } $index
    })
    if ($PSCmdlet.ShouldProcess($Path, 'Create the OPumper2 configuration')) {
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path }
        Save-OP2PumpList $Path $pumps
    }
    $pumps
}

function Get-OP2PumpRepair {
    # What repairs a pump whose folder is missing: the module that replaced it (a former name such as
    # FrenchExDev.Pnpm.OPumper2.PoSh becomes FrenchExDev.OPumper2.Node.PoSh), removal when another entry already
    # loads that module, or disabling it when nothing replaces it.
    param([object]$Pump, [object[]]$All)
    $folder = Split-Path $Pump.Path -Leaf
    $parent = Split-Path $Pump.Path
    $part = $(if ($folder -match '^FrenchExDev\.(?<old>[A-Za-z]+)\.OPumper2\.PoSh$') { $Matches.old } elseif ($folder -match '^FrenchExDev\.OPumper2\.(?<old>[A-Za-z]+)\.PoSh$') { $Matches.old })
    $current = $(if ($part -and $script:OP2PumpAliases.ContainsKey($part)) { $script:OP2PumpAliases[$part] } else { $part })
    $target = $(if ($current) { Join-Path $parent "FrenchExDev.OPumper2.$current.PoSh" })
    if ($target -and (Test-Path -LiteralPath $target -PathType Container)) {
        if (@($All | Where-Object { $_.Name -ne $Pump.Name -and $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($target) }).Count) {
            return [pscustomobject]@{ Name = $Pump.Name; Action = 'Remove'; Path = $target; Reason = 'AlreadyConfigured' }
        }
        return [pscustomobject]@{ Name = $Pump.Name; Action = 'Repath'; Path = $target; Reason = 'Renamed' }
    }
    return [pscustomobject]@{ Name = $Pump.Name; Action = $(if ($Pump.Enabled) { 'Disable' } else { 'None' }); Path = $null; Reason = 'NoReplacement' }
}

function Repair-OPumper2Configuration {
    # Proposes a repair for each pump whose folder is missing; Apply writes them (ShouldProcess still applies).
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Apply, [string]$ConfigurationPath = (Get-OP2ConfigurationPath))
    $pumps = @(Read-OP2PumpList $ConfigurationPath)
    $repairs = @(foreach ($pump in $pumps) { if ($pump.Path -and !$pump.Exists) { Get-OP2PumpRepair $pump $pumps } })
    if ($Apply -and $repairs.Count -and $PSCmdlet.ShouldProcess($ConfigurationPath, "Repair $($repairs.Count) pump(s)")) {
        $byName = @{}
        foreach ($repair in $repairs) { $byName[$repair.Name] = $repair }
        $kept = [Collections.Generic.List[object]]::new()
        foreach ($pump in $pumps) {
            $repair = $byName[$pump.Name]
            if ($repair -and $repair.Action -eq 'Remove') { continue }
            if ($repair -and $repair.Action -eq 'Repath') { $pump.Path = $repair.Path }
            if ($repair -and $repair.Action -eq 'Disable') { $pump.Enabled = $false }
            $kept.Add($pump)
        }
        Save-OP2PumpList $ConfigurationPath $kept.ToArray()
    }
    $repairs
}
