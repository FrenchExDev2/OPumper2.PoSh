#requires -Version 7.6
[CmdletBinding()]
param([ValidateSet('Engine','Git','Dotnet','Agent')][string]$Package = 'Engine')
$ErrorActionPreference='Stop'
$engine=Split-Path $PSScriptRoot
$parent=Split-Path $engine
. (Join-Path $PSScriptRoot 'ToolSupport.ps1')
$root=Join-Path $parent (Get-OP2TestPackage)[$Package]
try {
    Import-Module Pester -RequiredVersion 6.2.0
    Import-Module PSMutant -RequiredVersion 0.6.0
    $result=Invoke-PSMutation -ConfigFile (Join-Path $root 'test/psmutant.config.json') -SourceRoot $parent -ListOnly -Quiet
    @{Package=$Package;Preview=$result} | ConvertTo-Json -Depth 5 -Compress
} catch {@{Outcome='Failed';Error=$_.Exception.Message} | ConvertTo-Json -Compress;exit 1}
