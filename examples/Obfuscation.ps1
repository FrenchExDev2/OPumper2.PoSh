#requires -Version 7.6
[CmdletBinding()]
param()
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'FrenchExDev.OPumper2.PoSh.psd1') -DisableNameChecking
$executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$code = '"https://alice:s3cret@example.com/r.git","Authorization: Bearer abc.def","contact bob@example.com","host=build-07.internal" | ForEach-Object { [Console]::Out.WriteLine($_) }'
try {
    # A pattern middleware masks e-mail addresses in any delivered text.
    Register-OPumper2Obfuscator -Id example.email -TextPattern '[\w.+-]+@[\w-]+\.[\w.]+' -Replacement '[EMAIL]' | Out-Null
    # A script middleware uses the path: only the projected Data.Host value is masked.
    Register-OPumper2Obfuscator -Id example.host -Middleware {
        param($value, $context)
        if ($context.Path -eq 'Data.Host') { '[HOST]' }
    } | Out-Null
    $state = @{ Lines = [Collections.Generic.List[string]]::new(); Host = $null }
    Pump-Me $executable -ArgumentList @('-NoProfile','-NonInteractive','-Command',$code) -State $state `
        -OnStdOut { param($line,$s) if ($line -match '^host=(.+)$') { $s.Host = $Matches[1] } else { $s.Lines.Add($line) } } `
        -Complete { param($s,$execution) [pscustomobject]@{ Lines = $s.Lines.ToArray(); Host = $s.Host } } -AsYaml
} finally {
    Unregister-OPumper2Obfuscator example.email | Out-Null
    Unregister-OPumper2Obfuscator example.host | Out-Null
}
