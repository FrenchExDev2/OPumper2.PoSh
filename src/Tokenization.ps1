function Register-OPumper2Tokenizer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][scriptblock]$Count)
    $script:OP2Tokenizers[$Name] = @{ Version = $Version; Count = $Count }
}

function Get-OP2TokenCount {
    param([string]$Text, [string]$TokenizerName)
    if (!$script:OP2Tokenizers.ContainsKey($TokenizerName)) { Initialize-OP2Dependency }
    if (!$script:OP2Tokenizers.ContainsKey($TokenizerName)) { throw 'Unknown tokenizer.' }
    $value = @(& $script:OP2Tokenizers[$TokenizerName].Count $Text)
    if ($value.Count -ne 1 -or ($value[0] -isnot [long] -and $value[0] -isnot [int]) -or [long]$value[0] -lt 0) { throw 'Invalid tokenizer result.' }
    return [long]$value[0]
}

function Start-OP2TokenizerWarmup {
    # Loads the configured vocabulary in the background when the call will count tokens. A registered tokenizer has
    # no Warm step; an unknown name is left to the count, which reports it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Starts an in-memory background load; nothing outside the process changes.')]
    param([hashtable]$Configuration)
    if (!$Configuration.Tracking) { return }
    try {
        if (!$script:OP2Tokenizers.ContainsKey($Configuration.Tokenizer)) { Initialize-OP2Dependency }
        # A registered counter has no warm step and an unknown name no entry: invoking nothing fails like a failed
        # initialization, and lands in the same place.
        & $script:OP2Tokenizers[$Configuration.Tokenizer]['Warm']
    } catch {
        # Measurement never changes a call's outcome: the count reports the same failure as its status.
        return
    }
}

function Measure-OPumper2Token {
    # Tokens of a text under the configured tokenizer, for contributors that size outputs the engine did not deliver.
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return Get-OP2TokenCount $Text (Get-OP2Configuration).Tokenizer
}
