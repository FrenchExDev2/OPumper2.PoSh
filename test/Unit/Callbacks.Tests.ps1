BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Shared callback boundary' {
    It 'preserves array values while rejecting every diagnostic stream' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $values=@(Invoke-OP2DomainCallback {,@(1,2)} @())
            $values.Count | Should -Be 1
            $values[0] | Should -Be @(1,2)
            foreach($callback in @({Write-Error 'fixture' -ErrorAction Continue},{Write-Warning 'fixture'},{Write-Information 'fixture' -InformationAction Continue},{Write-Verbose 'fixture' -Verbose},{Write-Debug 'fixture' -Debug})) {
                {Invoke-OP2DomainCallback $callback @()} | Should -Throw '*domain values*'
            }
        }
    }
}
