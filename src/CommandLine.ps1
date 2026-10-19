function pump {
    # Command-line form of Pump-Me: options first, then the command and its arguments, passed verbatim. A simple
    # function receives native options such as -c, -o or -v unbound, where an advanced function would claim them.
    $call = ConvertFrom-OP2CommandLine $args $MyInvocation.Statement
    Pump-Me @call
}

function Get-OP2PumpOption {
    # Pump-Me parameters accepted before the command, mapped to whether each one is a switch. Read once per session:
    # command metadata costs tens of milliseconds on every pump call.
    if ($null -eq $script:OP2PumpOptions) {
        $excluded = @('Command','ArgumentList') + @([Management.Automation.Cmdlet]::CommonParameters) + @([Management.Automation.Cmdlet]::OptionalCommonParameters)
        $options = @{}
        foreach ($parameter in (Get-Command Pump-Me -CommandType Function).Parameters.Values) {
            if ($parameter.Name -notin $excluded) { $options[$parameter.Name] = $parameter.SwitchParameter }
        }
        $script:OP2PumpOptions = $options
    }
    return $script:OP2PumpOptions
}

function Test-OP2ParameterToken {
    # PowerShell marks the $args entries written as -name tokens; quoted strings and values are never options.
    param([object]$Value)
    return $Value -is [string] -and $null -ne $Value.PSObject.Properties['<CommandParameterName>']
}

function ConvertFrom-OP2CommandLine {
    # Parameter tokens before the command are Pump-Me options, by exact name; every entry after the command is a
    # native argument. PowerShell splits "-name:value" into two entries, which are joined again.
    param([object[]]$Arguments, [string]$Statement)
    $usage = 'Usage: pump [options] <command> [arguments].'
    $options = Get-OP2PumpOption
    $call = @{}; $index = 0
    while ($index -lt $Arguments.Count -and (Test-OP2ParameterToken $Arguments[$index])) {
        $token = [string]$Arguments[$index]; $index++
        $name = $token.Substring(1).TrimEnd(':')
        if (!$options.ContainsKey($name)) { throw "Unknown pump option '$token'. $usage" }
        if ($options[$name] -and !$token.EndsWith(':')) { $call[$name] = $true; continue }
        if ($index -eq $Arguments.Count) { throw "Missing value for pump option '$token'. $usage" }
        $call[$name] = $Arguments[$index]; $index++
    }
    if ($index -eq $Arguments.Count) { throw "Missing command. $usage" }
    $call.Command = [string]$Arguments[$index]
    $native = [Collections.Generic.List[string]]::new()
    for ($index++; $index -lt $Arguments.Count; $index++) {
        $value = $Arguments[$index]
        if ($value -is [scriptblock] -or $value -is [Collections.IDictionary]) { throw "Pump options precede the command; a script block or dictionary is not a native argument. $usage" }
        if ((Test-OP2ParameterToken $value) -and $value.EndsWith(':') -and $index+1 -lt $Arguments.Count) { $index++; $native.Add($value + $Arguments[$index]); continue }
        foreach ($item in @($value)) { if ($null -ne $item) { $native.Add([string]$item) } }
    }
    $call.ArgumentList = $native.ToArray()
    Assert-OP2Separator $Statement $options
    return $call
}

function Get-OP2ElementKind {
    param([object]$Element)
    if ($Element -is [Management.Automation.Language.CommandParameterAst]) { return $(if ($Element.ParameterName -eq '-') { 'Separator' } else { 'Option' }) }
    if ($Element -is [Management.Automation.Language.VariableExpressionAst] -and $Element.Splatted) { return 'Splat' }
    return 'Value'
}

function Assert-OP2Separator {
    # PowerShell removes the first -- of a function call before pump receives its arguments. Before the command it
    # only ends the options; after the command it was a native argument, which cannot be restored.
    param([string]$Statement, [hashtable]$Options)
    $ast = [Management.Automation.Language.Parser]::ParseInput($Statement, [ref]$null, [ref]$null)
    # A pump call inside a script block of this statement (such as a callback) is checked when it runs.
    $commands = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '(^|\\)pump$' }, $false)
    foreach ($command in $commands) {
        $elements = $command.CommandElements
        $index = 1
        while ($index -lt $elements.Count -and (Get-OP2ElementKind $elements[$index]) -in @('Option','Splat')) {
            $element = $elements[$index]; $index++
            if ((Get-OP2ElementKind $element) -eq 'Option' -and !$element.Argument -and !$Options[$element.ParameterName]) { $index++ }
        }
        # The options end at the separator or at the command; a separator after the command was removed from it.
        for ($index++; $index -lt $elements.Count; $index++) {
            if ((Get-OP2ElementKind $elements[$index]) -eq 'Separator') {
                throw "PowerShell removed the first '--' of this command line, which followed the command. Write one before the command as well: pump [options] -- <command> [arguments]."
            }
        }
    }
}
