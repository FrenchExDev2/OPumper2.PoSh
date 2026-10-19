function Resolve-OP2DatabasePath {
    # Explicit paths follow the PowerShell location; without one, the configured database.
    param([string[]]$Path, [hashtable]$Configuration)
    if (!$Path) { return @($Configuration.DatabasePath) }
    return @($Path | ForEach-Object { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) })
}

function Get-OPumper2Gain {
    # Captured source volume versus delivered JSON/YAML volume, from the local measurement history (like rtk gain).
    [CmdletBinding()]
    param([ValidateSet('Command','Route','Provider','Format','Outcome','Session','Project','Day','Week','Month')][string[]]$GroupBy,
        [ValidateRange(0,[int]::MaxValue)][int]$History = 0, [ValidateRange(0,[int]::MaxValue)][int]$Top = 0,
        [ValidateRange(0,[int]::MaxValue)][int]$Worst = 0, [switch]$Graph,
        [Nullable[datetime]]$Since, [string]$Project, [string]$Session, [string[]]$DatabasePath, [string]$Tier,
        [switch]$AsObject, [switch]$AsJson, [switch]$AsYaml, [switch]$AsText, [switch]$AsCsv, [switch]$AsLine)
    $configuration = Get-OP2Configuration
    $format = Get-OP2Format $PSBoundParameters $configuration
    $databases = Resolve-OP2DatabasePath $DatabasePath $configuration
    try {
        $read = [pscustomobject]@{ Rows = @(); Local = [ordered]@{ Invocations = 0L; SourceBytes = 0L; SourceTokens = 0L } }
        $existing = @($databases | Where-Object { Test-Path -LiteralPath $_ })
        if ($existing.Count) {
            Initialize-OP2Dependency
            if (!$script:OP2Tokenizers.ContainsKey($configuration.Tokenizer)) { throw 'Unknown tokenizer.' }
            $filter = @{ profile = $configuration.Tokenizer; version = $script:OP2Tokenizers[$configuration.Tokenizer].Version
                since = $(if ($null -ne $Since) { ([datetime]$Since).ToUniversalTime().ToString('O') } else { $null })
                project = $(if ($Project) { Get-OP2ProjectHash $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Project) } else { $null })
                session = $(if ($Session) { $Session } else { $null }) }
            $read = Read-OP2GainHistory $configuration $existing $filter
        }
        Add-OP2GainRerun $read.Rows $configuration.RecallWindowMinutes
        $complete = @($read.Rows | Where-Object Complete -EQ 1)
        $data = [ordered]@{ Profile = $configuration.Tokenizer; CounterVersion = $(if ($script:OP2Tokenizers.ContainsKey($configuration.Tokenizer)) { $script:OP2Tokenizers[$configuration.Tokenizer].Version } else { $null })
            Databases = $databases; Deliveries = $read.Rows.Count }
        $totals = Measure-OP2Gain $complete
        foreach ($name in $totals.Keys) { $data[$name] = $totals[$name] }
        $data.Local = $read.Local
        $cost = Get-OP2GainCost $totals $configuration
        if ($cost) { $data.Cost = $cost }
        $quota = Get-OP2GainQuota $complete $configuration -Tier $Tier
        if ($quota) { $data.Quota = $quota }
        if ($GroupBy) { $data.Groups = Get-OP2GainGroup $complete $GroupBy }
        if ($Top) { $data.Top = Select-OP2GainEntry $complete $Top -Descending }
        if ($Worst) { $data.Worst = Select-OP2GainEntry $complete $Worst }
        if ($History) { $data.History = @($read.Rows | Select-Object -Last $History | ForEach-Object { ConvertTo-OP2GainEntry $_ }) }
        if ($Graph) { $data.Graph = Get-OP2GainGraph $complete }
        $advice = @(Get-OP2GainAdvice (Get-OP2GainGroup $complete 'Command'))
        if ($advice.Count) { $data.Advice = $advice }
        $result = New-OP2Completion -Data $data
    } catch { $result = New-OP2Completion -Outcome Failed -ErrorInfo (New-OP2Error 'StorageUnavailable' 'Gain' $_.Exception) }
    # Reporting is deliberately not itself measured.
    if ($format -eq 'object') { return $result }
    if ($script:OP2GainRenderers.ContainsKey($format)) {
        if ($result.Outcome -ne 'Success') { return "OPumper2 gain unavailable: $($result.Error.Message)" }
        return & $script:OP2GainRenderers[$format] $result
    }
    Format-OPumper2Report $result $PSBoundParameters
}

function Watch-OPumper2Gain {
    # A live text report refreshed every IntervalSeconds; Count 0 refreshes until interrupted. Report holds the
    # Get-OPumper2Gain parameters, such as @{ GroupBy = 'Command'; Since = [datetime]::Today }.
    [CmdletBinding()]
    param([hashtable]$Report = @{}, [ValidateRange(0,[int]::MaxValue)][int]$IntervalSeconds = 5, [int]$Count = 0)
    for ($index = 0; $Count -eq 0 -or $index -lt $Count; $index++) {
        if ($index) { Start-Sleep -Seconds $IntervalSeconds }
        "OPumper2 gain at $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture))`n" + (Get-OPumper2Gain @Report -AsText)
    }
}
