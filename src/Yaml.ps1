function Get-OP2YamlSerializer {
    # powershell-yaml's own serializer (its YamlDotNet and string quoting emitter) with ConvertTo-Yaml -Options
    # DisableAliases settings, built once per session. ConvertTo-Yaml builds it again and walks the whole graph in
    # PowerShell on every call; protected values are already the dictionaries, lists and scalars that walk produces, so
    # the text is the same while delivering costs a fraction.
    if ($null -eq $script:OP2YamlSerializer) {
        $yamlDotNet, $quoting = Get-OP2YamlAssembly
        $builder = $yamlDotNet.GetType('YamlDotNet.Serialization.SerializerBuilder')::new().DisableAliases()
        $script:OP2YamlSerializer = $quoting.GetType('BuilderUtils')::BuildSerializer($builder, $false, $false, $false, $false).Build()
    }
    return $script:OP2YamlSerializer
}

function Get-OP2YamlAssembly {
    # powershell-yaml's YamlDotNet and string quoting emitter, loaded directly once per session: importing the module
    # costs about 200 ms per process, the load a few. The pair lives in its own load context: loaded into the default
    # one, it would capture the YamlDotNet references of a powershell-yaml imported later and break ConvertTo-Yaml, and
    # the module's own copies cannot be reused either. Isolated, both work in any import order.
    if ($null -eq $script:OP2YamlAssemblies) {
        $library = Get-OP2YamlLibrary
        $context = [Runtime.Loader.AssemblyLoadContext]::new('FrenchExDev.OPumper2.Yaml')
        $script:OP2YamlAssemblies = @($context.LoadFromAssemblyPath((Join-Path $library 'YamlDotNet.dll')),
            $context.LoadFromAssemblyPath((Join-Path $library 'PowerShellYamlSerializer.dll')))
    }
    return $script:OP2YamlAssemblies
}

function Get-OP2YamlLibrary {
    # The assembly folder of the pinned powershell-yaml 0.4.12, by its versioned path under each module root (the
    # engine's .cache/Modules first, then the process module path): listing every module would cost 65 ms per process.
    param([string[]]$ModuleRoot = @(@(Join-Path $script:OP2Root '.cache/Modules') + @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ })))
    foreach ($root in $ModuleRoot) {
        $library = Join-Path $root 'powershell-yaml/0.4.12/lib/netstandard2.1'
        if (Test-Path -LiteralPath (Join-Path $library 'YamlDotNet.dll') -PathType Leaf) { return $library }
    }
    throw 'powershell-yaml 0.4.12 is required: run build/Initialize-Dependencies.ps1 -Tools.'
}

function ConvertFrom-OP2Yaml {
    # The first document of a YAML text exactly as ConvertFrom-Yaml (powershell-yaml 0.4.12) returns it: hashtables,
    # lists of objects and scalars typed by the same rules. YamlDotNet parses; reading a file costs no module import.
    param([string]$Yaml)
    if (!$Yaml) { return }
    $yamlDotNet = (Get-OP2YamlAssembly)[0]
    $reader = [IO.StringReader]::new($Yaml + "`n")
    try {
        $stream = $yamlDotNet.GetType('YamlDotNet.RepresentationModel.YamlStream')::new()
        $stream.Load($yamlDotNet.GetType('YamlDotNet.Core.Parser')::new($reader))
    } finally { $reader.Dispose() }
    if (!$stream.Documents.Count) { return }
    return ConvertFrom-OP2YamlNode $stream.Documents[0].RootNode
}

function ConvertFrom-OP2YamlNode {
    param([object]$Node)
    if ($Node.GetType().Name -eq 'YamlMappingNode') {
        $map = @{}
        foreach ($key in $Node.Children.Keys) { $map[$key.Value] = ConvertFrom-OP2YamlNode $Node.Children[$key] }
        return $map
    }
    if ($Node.GetType().Name -eq 'YamlSequenceNode') {
        $list = [Collections.Generic.List[object]]::new()
        foreach ($child in $Node.Children) { $list.Add((ConvertFrom-OP2YamlNode $child)) }
        return ,$list
    }
    return ConvertFrom-OP2YamlScalar $Node
}

function ConvertFrom-OP2YamlScalar {
    # The scalar typing of powershell-yaml 0.4.12 (Convert-ValueToProperType, Apache-2.0, Cloudbase Solutions), with the
    # same .NET calls in the same order: an explicit tag decides first, then a plain scalar is tried as a boolean, an
    # integer (int, long, then BigInteger), a decimal, a double, and a null spelling; anything else is its text.
    param([object]$Node)
    $styles = [Globalization.NumberStyles]::Float -bor [Globalization.NumberStyles]::Integer
    $culture = [Globalization.CultureInfo]::InvariantCulture
    switch ([string]$Node.Tag) {
        'tag:yaml.org,2002:str' { return $Node.Value }
        'tag:yaml.org,2002:null' { return $null }
        'tag:yaml.org,2002:bool' {
            $parsed = $null
            if (![bool]::TryParse($Node.Value, [ref]$parsed)) { throw "failed to parse scalar $($Node.Value) as boolean" }
            return $parsed
        }
        'tag:yaml.org,2002:int' {
            $parsed = [Numerics.BigInteger]::Zero
            $prefix = $(if ($Node.Value.Length -gt 2) { $Node.Value.Substring(0, 2) })
            if ($prefix -eq '0o') { $parsed = [Convert]::ToInt64($Node.Value.Substring(2), 8) }
            elseif ($prefix -eq '0x') { $parsed = [Convert]::ToInt64($Node.Value.Substring(2), 16) }
            elseif (![Numerics.BigInteger]::TryParse($Node.Value, $styles, $culture, [ref]$parsed)) { throw "failed to parse scalar $($Node.Value) as long" }
            return ConvertTo-OP2YamlInteger $parsed
        }
        'tag:yaml.org,2002:float' {
            if ($Node.Value -cmatch '^[-+]?(\.inf|\.Inf|\.INF)$') { return $(if ($Node.Value.StartsWith('-')) { [double]::NegativeInfinity } else { [double]::PositiveInfinity }) }
            $parsed = $null
            if (![decimal]::TryParse($Node.Value, [Globalization.NumberStyles]::Float, $culture, [ref]$parsed)) { throw "failed to parse scalar $($Node.Value) as decimal" }
            return $parsed
        }
        'tag:yaml.org,2002:timestamp' {
            [DateTime]$parsed = [DateTime]::MinValue
            $text = [DateTime]::SpecifyKind($Node.Value, [DateTimeKind]::Utc).ToString('o')
            [void][DateTime]::TryParse($text, $null, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
            return $parsed
        }
    }
    if ($Node.Style -eq 'Plain') {
        $boolean = $null
        if ([bool]::TryParse($Node.Value, [ref]$boolean)) { return $boolean }
        $integer = [Numerics.BigInteger]::Zero
        if ([Numerics.BigInteger]::TryParse($Node.Value, $styles, $culture, [ref]$integer)) { return ConvertTo-OP2YamlInteger $integer }
        $number = $null
        if ([decimal]::TryParse($Node.Value, [Globalization.NumberStyles]::Float, $culture, [ref]$number)) { return $number }
        $real = $null
        if ([double]::TryParse($Node.Value, [Globalization.NumberStyles]::Float, $culture, [ref]$real)) { return $real }
        # -in, as powershell-yaml compares: any casing of null is null.
        if ($Node.Value -in @('', '~', 'null', 'Null', 'NULL')) { return $null }
    }
    return $Node.Value
}

function ConvertTo-OP2YamlInteger {
    # The smallest of int and long that holds the value, as powershell-yaml returns it; a BigInteger otherwise.
    param([object]$Value)
    foreach ($type in @([int], [long])) {
        $converted = $Value -as $type
        if ($null -ne $converted) { return $converted }
    }
    return $Value
}

