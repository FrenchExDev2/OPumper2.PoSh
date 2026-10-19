function Get-OP2EnvironmentValue {
    param([string]$Name)
    # Process environment variables are shared by every runspace; a runspace-local substitute keeps
    # concurrent hosts (such as parallel mutation workers) isolated. Null means the real environment.
    if ($null -ne $script:OP2Environment) { return $script:OP2Environment[$Name] }
    return [Environment]::GetEnvironmentVariable($Name)
}

function Use-OPumper2Environment {
    # Gives the engine, in this runspace, an environment of its own instead of the process's: the variables it reads
    # (OPUMPER2_DB_PATH, OPUMPER2_CONFIG_PATH, OPUMPER2_TRACKING...) come from Environment alone. With a script block,
    # for that block only, the previous environment restored after it; without, until the next call. Reset returns to
    # the process environment. Tests and concurrent hosts (parallel runspaces of one process) isolate themselves so.
    [CmdletBinding(DefaultParameterSetName = 'Use')]
    param([Parameter(Mandatory, Position = 0, ParameterSetName = 'Use')][Collections.IDictionary]$Environment,
        [Parameter(Position = 1, ParameterSetName = 'Use')][scriptblock]$ScriptBlock,
        [Parameter(Mandatory, ParameterSetName = 'Reset')][switch]$Reset)
    $substitute = $null
    if (!$Reset) {
        # A copy: later changes to the caller's dictionary do not reach the engine.
        $substitute = @{}
        foreach ($name in $Environment.get_Keys()) { $substitute[$name] = $Environment[$name] }
    }
    if (!$ScriptBlock) { $script:OP2Environment = $substitute; return }
    $previous = $script:OP2Environment
    $script:OP2Environment = $substitute
    try { & $ScriptBlock } finally { $script:OP2Environment = $previous }
}

function Read-OP2ConfigurationDocument {
    # The parsed configuration file. Parsing YAML costs milliseconds and one call can read the configuration thousands of
    # times (a token count per transcript result reads it): the text is parsed again only when it changed. YamlDotNet
    # parses it directly, typed as ConvertFrom-Yaml would: importing powershell-yaml would cost every call 200 ms.
    param([string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    if ($text -cne $script:OP2ConfigurationText) {
        $script:OP2ConfigurationDocument = ConvertFrom-OP2Yaml $text
        $script:OP2ConfigurationText = $text
    }
    return $script:OP2ConfigurationDocument
}

function Get-OP2Configuration {
    [CmdletBinding()]
    param([string]$Path = (Get-OP2ConfigurationPath))
    $settings = @{
        OutputFormat = 'yaml'; MaxItems = 20; MaxOutputBytes = 8192; TimeoutSeconds = 600; ExcerptLines = 20
        DatabasePath = (Join-Path $HOME '.opumper2/db.sqlite'); Tokenizer = 'o200k_base'
        # Measurement history: retention (0 keeps everything), recall window, alternate format, session variable.
        RetentionDays = 90; RecallWindowMinutes = 30; MeasureAlternateFormat = $false; SessionVariable = 'OPUMPER2_SESSION'
        # Optional valuation of the history: price per million tokens, a monthly token budget, or named budgets.
        TokenPrice = $null; Currency = 'USD'; MonthlyTokenBudget = $null; QuotaTiers = @{}; QuotaTier = $null
        # Tracking off stores nothing. A compact envelope delivers outcome, Data, exit code, errors and excerpts only.
        Tracking = $true; Envelope = 'full'
        # The recall store keeps delivered outputs (on), failed ones only (failures), or nothing (off).
        Recall = 'on'; RecallRetentionDays = 30; RecallMaxEntries = 200; RecallMaxEntryBytes = 10485760; RecallMask = $true
        # Agent hooks: what a shell command run without pump triggers, and the commands they leave alone.
        HookAwareness = 'warn'; HookExcludeCommands = @()
    }
    if (Test-Path -LiteralPath $Path) {
        # A mapping of sections: general holds these settings, pumps the contributors Import-OPumper2Workspace loads.
        $document = Read-OP2ConfigurationDocument $Path
        if ($document -isnot [Collections.IDictionary]) { throw 'Configuration must be a mapping of sections.' }
        foreach ($section in $document.get_Keys()) { if ($section -notin @('general','pumps')) { throw "Unknown configuration section: $section" } }
        $general = $document['general']
        if ($null -ne $general) {
            if ($general -isnot [Collections.IDictionary]) { throw 'The general section must be a mapping.' }
            foreach ($key in $general.get_Keys()) {
                if (!$settings.ContainsKey($key)) { throw "Unknown general setting: $key" }
                $settings[$key] = $general[$key]
            }
        }
    }
    $database = Get-OP2EnvironmentValue 'OPUMPER2_DB_PATH'
    if ($database) { $settings.DatabasePath = $database }
    if ($settings.DatabasePath.StartsWith('~/')) { $settings.DatabasePath = Join-Path $HOME $settings.DatabasePath.Substring(2) }
    if ($settings.OutputFormat -notin @('yaml','json','object')) { throw 'Unknown output format.' }
    [void](Resolve-OP2CallLimit -Configuration $settings)
    if ($settings.RetentionDays -lt 0 -or $settings.RecallWindowMinutes -lt 0 -or $settings.RecallRetentionDays -lt 0 -or $settings.RecallMaxEntries -lt 0 -or $settings.RecallMaxEntryBytes -le 0) {
        throw 'Invalid measurement history setting.'
    }
    if ($settings.Envelope -notin @('full','compact') -or $settings.Recall -notin @('on','failures','off') -or $settings.HookAwareness -notin @('off','warn','deny','rewrite')) {
        throw 'Unknown envelope, recall or hook awareness mode.'
    }
    # One call or one process can switch measurement, the recall store and agent hooks off: OPUMPER2_TRACKING=0,
    # OPUMPER2_RECALL=0, OPUMPER2_HOOK=0.
    if ((Get-OP2EnvironmentValue 'OPUMPER2_TRACKING') -eq '0') { $settings.Tracking = $false }
    if ((Get-OP2EnvironmentValue 'OPUMPER2_RECALL') -eq '0') { $settings.Recall = 'off' }
    if ((Get-OP2EnvironmentValue 'OPUMPER2_HOOK') -eq '0') { $settings.HookAwareness = 'off' }
    return $settings
}

function Get-OPumper2Configuration {
    # The effective configuration, for contributors and agent integrations.
    [CmdletBinding()]
    param()
    return Get-OP2Configuration
}

function Get-OP2Format {
    param([hashtable]$Bound, [hashtable]$Configuration)
    # AsText, AsCsv and AsLine exist only on reports, such as Get-OPumper2Gain.
    $formats = [ordered]@{ AsObject = 'object'; AsJson = 'json'; AsYaml = 'yaml'; AsText = 'text'; AsCsv = 'csv'; AsLine = 'line' }
    $selected = @($formats.Keys | Where-Object { $Bound.ContainsKey($_) -and $Bound[$_] })
    if ($selected.Count -gt 1) { throw 'Output controls are mutually exclusive.' }
    if (!$selected.Count) { return $Configuration.OutputFormat }
    return $formats[$selected[0]]
}
