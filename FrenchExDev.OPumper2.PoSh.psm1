#requires -Version 7.6
#requires -PSEdition Core
Set-StrictMode -Version Latest
# What importing the engine costs, charged to the first delivery the session stores (Save-OP2Delivery).
$script:OP2ImportStarted = [Diagnostics.Stopwatch]::GetTimestamp()
$script:OP2Root = $PSScriptRoot
$script:OP2Routes = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$script:OP2CurrentCall = $null
$script:OP2Tokenizers = @{}
$script:OP2Obfuscators = [Collections.Generic.List[object]]::new()
$script:OP2Environment = $null
$script:OP2PumpOptions = $null
$script:OP2YamlSerializer = $null
$script:OP2YamlAssemblies = $null
$script:OP2ConfigurationText = $null
$script:OP2ConfigurationDocument = $null

foreach ($part in @('Configuration','Configuration.Pumps','Options','Context','Result','Callbacks','Registry','Dependencies','Tokenization','Schema','Storage','Measurement','Gain.Query','Gain.Aggregate','Gain.Advice','Gain.Render','Gain','Audit','Maintenance','Obfuscation','Yaml','Protection','Budget','Delivery','Serialization','Projection','Recall','Shadow','Bypass','Route','Filter.Definition','Filter.Contract','Filter.Summary','Filter.Catalogue','Filter.Registration','Filter.Test','Process','Framing','Native','Task','Pump-Me','CommandLine')) {
    . (Join-Path $PSScriptRoot "src/$part.ps1")
}
# The engine assembly (engine/, built into resources/runtime by build/Initialize-Dependencies.ps1): native streams are
# read, decoded and framed off this thread.
[void](Import-OP2EngineAssembly (Join-Path $PSScriptRoot 'resources/runtime/FrenchExDev.OPumper2.Engine.dll'))
Initialize-OP2Obfuscator
$script:OP2ImportMs = Get-OP2Duration $script:OP2ImportStarted (Get-OP2Timestamp)
$script:OP2ImportPending = $true
