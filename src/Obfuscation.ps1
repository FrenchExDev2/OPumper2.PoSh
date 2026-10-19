function New-OP2Obfuscator {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates an in-memory pipeline entry without external side effects.')]
    param([string]$Id, [string]$Kind, [string]$Pattern, [string]$Replacement, [scriptblock]$Middleware, [bool]$BuiltIn)
    # Pattern entries run as compiled .NET regular expressions; only Script entries invoke PowerShell code.
    $regex = $(if ($Kind -ne 'Script') { [regex]::new($Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase) } else { $null })
    [pscustomobject]@{ Id = $Id; Kind = $Kind; Regex = $regex; Replacement = $Replacement; Middleware = $Middleware; BuiltIn = $BuiltIn }
}

function Initialize-OP2Obfuscator {
    $script:OP2Obfuscators.Clear()
    $script:OP2Obfuscators.Add((New-OP2Obfuscator 'builtin.secret-keys' Key '^(password|passwd|secret|token|api[_-]?key|authorization|credential|environment)$' '[REDACTED]' -BuiltIn $true))
    $script:OP2Obfuscators.Add((New-OP2Obfuscator 'builtin.secret-assignments' Text '(password|token|api[_-]?key|authorization)\s*[:=]\s*(?:(?:bearer|basic|digest|token)\s+)?[^\s;,]+' '$1=[REDACTED]' -BuiltIn $true))
    $script:OP2Obfuscators.Add((New-OP2Obfuscator 'builtin.bearer' Text '\b(bearer)\s+[a-z0-9._~+/-]+=*' '$1 [REDACTED]' -BuiltIn $true))
    $script:OP2Obfuscators.Add((New-OP2Obfuscator 'builtin.url-credentials' Text '\b([a-z][a-z0-9+.-]*://)[^/\s@?#]+@' '$1[REDACTED]@' -BuiltIn $true))
}

function Invoke-OP2Obfuscation {
    param([object]$Value, [hashtable]$Context, [hashtable]$Limits)
    foreach ($entry in $script:OP2Obfuscators.ToArray()) {
        if ($entry.Kind -eq 'Key') {
            if ($null -ne $Context.Key -and $entry.Regex.IsMatch([string]$Context.Key)) { $Value = $entry.Replacement }
            continue
        }
        if ($entry.Kind -eq 'Text') {
            if ($Value -is [string]) { $Value = $entry.Regex.Replace($Value, $entry.Replacement) }
            continue
        }
        # No output keeps the value, one output replaces it; anything else fails closed.
        try { $output = @(Invoke-OP2DomainCallback $entry.Middleware @($Value,$Context)) }
        catch { $output = $null }
        if ($null -eq $output -or $output.Count -gt 1) {
            if ($Limits) { $Limits.ObfuscationFailed = $true }
            return '[OBFUSCATION FAILED]'
        }
        if ($output.Count) { $Value = $output[0] }
    }
    return ,$Value
}

function Register-OPumper2Obfuscator {
    [CmdletBinding(DefaultParameterSetName='Script')]
    param([Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory,ParameterSetName='Script')][scriptblock]$Middleware,
        [Parameter(Mandatory,ParameterSetName='Key')][string]$KeyPattern,
        [Parameter(Mandatory,ParameterSetName='Text')][string]$TextPattern,
        [Parameter(ParameterSetName='Key')][Parameter(ParameterSetName='Text')][string]$Replacement = '[REDACTED]',
        [string]$Before)
    if ([string]::IsNullOrWhiteSpace($Id) -or $Id -like 'builtin.*') { throw 'Obfuscator identifiers must be non-empty and outside the builtin prefix.' }
    if (@($script:OP2Obfuscators | Where-Object Id -eq $Id).Count) { throw 'Duplicate obfuscator identifier.' }
    $pattern = $(if ($PSCmdlet.ParameterSetName -eq 'Key') { $KeyPattern } else { $TextPattern })
    $entry = New-OP2Obfuscator $Id $PSCmdlet.ParameterSetName $pattern $Replacement $Middleware -BuiltIn $false
    $position = $script:OP2Obfuscators.Count
    if ($Before) {
        $target = @($script:OP2Obfuscators | Where-Object Id -eq $Before)
        if (!$target.Count) { throw 'Unknown obfuscator to insert before.' }
        $position = $script:OP2Obfuscators.IndexOf($target[0])
    }
    $script:OP2Obfuscators.Insert($position, $entry)
    [pscustomobject]@{ Id = $Id; Kind = $entry.Kind; Position = $position; BuiltIn = $false }
}

function Unregister-OPumper2Obfuscator {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $entries = @($script:OP2Obfuscators | Where-Object Id -eq $Id)
    if (@($entries | Where-Object BuiltIn).Count) { throw 'Built-in obfuscators cannot be removed.' }
    foreach ($entry in $entries) { [void]$script:OP2Obfuscators.Remove($entry) }
    return ($entries.Count -gt 0)
}

function Get-OPumper2Obfuscator {
    [CmdletBinding()]
    param()
    for ($index = 0; $index -lt $script:OP2Obfuscators.Count; $index++) {
        $entry = $script:OP2Obfuscators[$index]
        [pscustomobject]@{ Id = $entry.Id; Kind = $entry.Kind; Position = $index; BuiltIn = $entry.BuiltIn }
    }
}
