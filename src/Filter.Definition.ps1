# The keys a catalogue entry may hold, and the names a group cannot take because the projection uses them.
$script:OP2FilterKeys = @('Id','Routes','Description','Source','Environment','Arguments','SuccessExitCodes','Drop','Keep','Dedupe','Counters','Groups','Captures','Tests')
$script:OP2FilterTestKeys = @('Name','Lines','ExitCode','Stream','Expect','Absent')
$script:OP2FilterReserved = @('Filter','Succeeded','Lines','Dropped','Counters','Captures','Kept','Omitted')

function ConvertTo-OP2FilterRegex {
    param([string]$Pattern, [string]$Origin)
    try { return [regex]::new($Pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant) }
    catch { throw "$Origin`: invalid expression '$Pattern'." }
}

function Get-OP2FilterMap {
    # An optional block of a catalogue entry, empty when absent.
    param([Collections.IDictionary]$Definition, [string]$Name)
    if ($Definition[$Name]) { return $Definition[$Name] }
    return @{}
}

function ConvertTo-OP2FilterDefinition {
    # Validates one catalogue entry and compiles its expressions. A counter keeps the last (?<value>) it matched, sums
    # (?<sum>), or counts matching lines; a group counts lines per (?<key>); a capture keeps the last matching line, or
    # its (?<text>).
    param([Collections.IDictionary]$Definition, [string]$Origin)
    $where = "$Origin ($($Definition['Id']))"
    foreach ($key in $Definition.get_Keys()) { if ($key -notin $script:OP2FilterKeys) { throw "$where`: unknown key '$key'." } }
    if (!$Definition['Id']) { throw "$Origin`: a filter needs an Id." }
    if (!@($Definition['Routes'] | Where-Object { $_ }).Count) { throw "$where`: a filter needs Routes." }
    $counters = [ordered]@{}; $map = Get-OP2FilterMap $Definition 'Counters'
    foreach ($name in @(@($map.get_Keys()) | Sort-Object)) {
        $regex = ConvertTo-OP2FilterRegex $map[$name] $where
        $groups = $regex.GetGroupNames()
        $mode = $(if ('value' -in $groups) { 'Last' } elseif ('sum' -in $groups) { 'Sum' } else { 'Count' })
        $counters[$name] = [pscustomobject]@{ Regex = $regex; Mode = $mode }
    }
    $groups = [ordered]@{}; $map = Get-OP2FilterMap $Definition 'Groups'
    foreach ($name in @(@($map.get_Keys()) | Sort-Object)) {
        if ($name -in $script:OP2FilterReserved) { throw "$where`: '$name' is a reserved group name." }
        $regex = ConvertTo-OP2FilterRegex $map[$name] $where
        if ('key' -notin $regex.GetGroupNames()) { throw "$where`: group '$name' needs a (?<key>...) capture." }
        $groups[$name] = $regex
    }
    $captures = [ordered]@{}; $map = Get-OP2FilterMap $Definition 'Captures'
    foreach ($name in @(@($map.get_Keys()) | Sort-Object)) { $captures[$name] = ConvertTo-OP2FilterRegex $map[$name] $where }
    $tests = @(ConvertTo-OP2FilterTest $Definition['Tests'] $counters $groups $captures ([bool]@($Definition['Keep'] | Where-Object { $_ }).Count) $where)
    [pscustomobject]@{
        PSTypeName = 'OPumper2.FilterDefinition'
        Id = [string]$Definition['Id']; Routes = @($Definition['Routes']); Description = $Definition['Description']; Source = $Definition['Source']
        Environment = $(if ($Definition['Environment']) { $Definition['Environment'].Clone() } else { @{} })
        Arguments = @($Definition['Arguments'] | Where-Object { $null -ne $_ })
        SuccessExitCodes = $(if ($Definition.Contains('SuccessExitCodes')) { [int[]]@($Definition['SuccessExitCodes']) } else { [int[]]@(0) })
        Drop = @(@($Definition['Drop'] | Where-Object { $_ }) | ForEach-Object { ConvertTo-OP2FilterRegex $_ $where })
        Keep = @(@($Definition['Keep'] | Where-Object { $_ }) | ForEach-Object { ConvertTo-OP2FilterRegex $_ $where })
        Dedupe = $(if ($Definition.Contains('Dedupe')) { [bool]$Definition['Dedupe'] } else { $true })
        Counters = $counters; Groups = $groups; Captures = $captures; Tests = $tests; Origin = $Origin
    }
}

function Test-OP2FilterSection {
    # Whether a summary section is one the filter can deliver: Filter, Succeeded and Lines always; Kept with a Keep;
    # Counters.<name> and Captures.<name> when declared; <Group>.<key> for a declared group. Whole names the section
    # itself (Counters, Captures, a group), which an Absent entry may.
    param([string]$Section, [Collections.IDictionary]$Counters, [Collections.IDictionary]$Groups, [Collections.IDictionary]$Captures, [bool]$Keeps, [switch]$Whole)
    if ($Section -in @('Filter', 'Succeeded', 'Lines')) { return $true }
    if ($Section -eq 'Kept') { return $Keeps }
    $parts = $Section -split '\.', 2
    if ($parts.Count -eq 1) { return $Whole -and ($Section -in @('Counters', 'Captures') -or $Groups.Contains($Section)) }
    if ($parts[0] -eq 'Counters') { return $Counters.Contains($parts[1]) }
    if ($parts[0] -eq 'Captures') { return $Captures.Contains($parts[1]) }
    return $Groups.Contains($parts[0])
}

function ConvertTo-OP2FilterTest {
    # The tests a catalogue entry carries: recorded Lines, their ExitCode and Stream, and what the delivered summary
    # must hold (Expect: section = text, arrays joined with '|') or leave out (Absent). A test naming a section the
    # filter cannot deliver is an error at load time.
    param([object]$Tests, [Collections.IDictionary]$Counters, [Collections.IDictionary]$Groups, [Collections.IDictionary]$Captures, [bool]$Keeps, [string]$Where)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($test in @($Tests | Where-Object { $null -ne $_ })) {
        if ($test -isnot [Collections.IDictionary]) { throw "$Where`: a test must be a mapping." }
        foreach ($key in $test.get_Keys()) { if ($key -notin $script:OP2FilterTestKeys) { throw "$Where`: unknown test key '$key'." } }
        $name = [string]$test['Name']
        if (!$name) { throw "$Where`: a test needs a Name." }
        $label = "$Where test '$name'"
        if (!$names.Add($name)) { throw "$Where`: duplicate test '$name'." }
        $lines = @($test['Lines'] | Where-Object { $null -ne $_ })
        if (@($lines | Where-Object { $_ -isnot [string] }).Count) { throw "$label`: Lines must be strings." }
        $exit = $(if ($test.Contains('ExitCode')) { $test['ExitCode'] } else { 0 })
        if ($exit -isnot [int]) { throw "$label`: ExitCode must be an integer." }
        $stream = $(if ($test.Contains('Stream')) { $test['Stream'] } else { 'stdout' })
        if ($stream -notin @('stdout', 'stderr')) { throw "$label`: Stream must be stdout or stderr." }
        $expect = $(if ($test.Contains('Expect')) { $test['Expect'] } else { @{} })
        if ($expect -isnot [Collections.IDictionary]) { throw "$label`: Expect must be a mapping." }
        $absent = @($test['Absent'] | Where-Object { $null -ne $_ })
        if (!$expect.Count -and !$absent.Count) { throw "$label`: a test needs Expect or Absent." }
        foreach ($section in $expect.get_Keys()) {
            if (!(Test-OP2FilterSection $section $Counters $Groups $Captures $Keeps)) { throw "$label`: Expect names '$section', which the filter does not deliver." }
        }
        foreach ($section in $absent) {
            if (!(Test-OP2FilterSection $section $Counters $Groups $Captures $Keeps -Whole)) { throw "$label`: Absent names '$section', which the filter does not deliver." }
        }
        [pscustomobject]@{ Name = $name; Lines = [string[]]$lines; ExitCode = $exit; Stream = $stream; Expect = $expect; Absent = [string[]]$absent }
    }
}

function Get-OPumper2Filter {
    # The validated catalogue of a folder: every *.psd1 it holds, each holding Filters = @(...). Catalogues belong to
    # their ecosystem modules (Git, Node, Python...); the engine only interprets them.
    [CmdletBinding()]
    param([string[]]$Id, [Parameter(Mandatory)][string]$Path)
    $definitions = @(foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter '*.psd1' -File | Sort-Object Name)) {
        foreach ($entry in @((Import-PowerShellDataFile -LiteralPath $file.FullName).Filters)) { ConvertTo-OP2FilterDefinition $entry $file.Name }
    })
    $duplicates = @($definitions | Group-Object Id | Where-Object Count -GT 1 | ForEach-Object Name)
    if ($duplicates.Count) { throw "Duplicate filter: $($duplicates -join ', ')." }
    if (!$Id) { return $definitions }
    $unknown = @($Id | Where-Object { $_ -notin $definitions.Id })
    if ($unknown.Count) { throw "Unknown filter: $($unknown -join ', ')." }
    return @($definitions | Where-Object Id -In $Id)
}
