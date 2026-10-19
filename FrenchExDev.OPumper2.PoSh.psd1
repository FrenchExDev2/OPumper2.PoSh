@{
    RootModule = 'FrenchExDev.OPumper2.PoSh.psm1'
    ModuleVersion = '1.0.0'
    GUID = '4f343091-6039-4aa6-b182-deeb63de918a'
    Author = 'FrenchExDev'
    Description = 'AI-defined output contracts, native execution, routing, declarative filters and local measurements.'
    PowerShellVersion = '7.6'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('Pump-Me','pump','Invoke-OPumper2Task','New-OPumper2Result','Register-OPumper2','Unregister-OPumper2','Resolve-OPumper2Command','ConvertTo-OPumper2Output','Out-OPumper2','New-OPumper2Configuration','Get-OPumper2Pump','Add-OPumper2Pump','Remove-OPumper2Pump','Enable-OPumper2Pump','Disable-OPumper2Pump','Repair-OPumper2Configuration','Get-OPumper2Gain','Get-OPumper2Audit','Watch-OPumper2Gain','Clear-OPumper2Measurement','Get-OPumper2Configuration','Use-OPumper2Environment','Measure-OPumper2Token','Format-OPumper2Report','Invoke-OPumper2Route','Limit-OPumper2Projection','ConvertTo-OPumper2Line','Get-OPumper2Recall','Invoke-OPumper2Recall','Measure-OPumper2Contract','Invoke-OPumper2Bypass','Get-OPumper2Filter','Test-OPumper2Filter','New-OPumper2FilterContract','ConvertTo-OPumper2FilterSummary','ConvertTo-OPumper2FilterCatalogue','Register-OPumper2Filter','Register-OPumper2Tokenizer','Register-OPumper2Obfuscator','Unregister-OPumper2Obfuscator','Get-OPumper2Obfuscator')
    AliasesToExport = @()
    CmdletsToExport = @()
    VariablesToExport = @()
    PrivateData = @{ PSData = @{ Tags = @('Output','AI','PSEdition_Core'); LicenseUri = 'https://opensource.org/license/mit' } }
}
