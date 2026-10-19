BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Completion envelope and metadata composition' {
    It 'has a versioned, untruncated default with unknown native exit code' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $r=New-OP2Completion
            $r.Kind | Should -Be 'Completion'
            $r.SchemaVersion | Should -Be 2
            $r.Execution.ExitCode | Should -BeNullOrEmpty
            $r.Execution.InvocationIds.Count | Should -Be 0
            $r.Execution.ElapsedMs | Should -BeNullOrEmpty
            $r.Completeness.Source | Should -BeTrue
            $r.Completeness.Analysis | Should -BeTrue
            $r.Truncation.Applied | Should -BeFalse
            $r.Truncation.OmittedRecords | Should -Be 0
            $r.Truncation.Reasons.Count | Should -Be 0
            $r.Measurement.Status | Should -Be 'NotDelivered'
            foreach($outcome in @('Failed','Timeout','Cancelled','Unsupported')) {
                $failed=New-OP2Completion -Outcome $outcome
                $failed.Completeness.Source | Should -BeFalse
                $failed.Completeness.Analysis | Should -BeFalse
            }
        }
    }
    It 'builds a handler result, accounted like any step of the current task' {
        $result=New-OPumper2Result -Data @{Value=42}
        $result.Kind | Should -Be 'Completion'
        $result.Outcome | Should -Be 'Success'
        $result.Error | Should -BeNullOrEmpty
        $result.Data.Value | Should -Be 42
        $result.Presentation.Projection | Should -BeNullOrEmpty
        $result.Presentation.ExcerptLines | Should -BeNullOrEmpty
        $failed=New-OPumper2Result -Outcome Failed -ErrorCode Unparsable -ErrorMessage 'line 3'
        $failed.Error.Code | Should -Be 'Unparsable'
        $failed.Error.Phase | Should -Be 'Handler'
        $failed.Error.Message | Should -BeExactly 'line 3'
        $failed.Completeness.Analysis | Should -BeFalse
        (New-OPumper2Result -Outcome Timeout).Error.Code | Should -Be 'HandlerFailed'
        $task=Invoke-OPumper2Task -AsObject -ScriptBlock { New-OPumper2Result -Outcome Failed -ErrorCode Unparsable | Out-Null; 'body' }
        $task.Outcome | Should -Be 'Failed'
        $task.Execution.Issues[0].Error.Code | Should -Be 'Unparsable'
    }
    It 'wraps a completion without changing it and validates the wrapped object' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $native=New-OP2Completion -Outcome Failed -Data @{Rich=1} -ErrorInfo (New-OP2Error 'NativeFailed' 'Execution')
            $native.Capture=@{Stdout='out';Stderr=$null;Complete=$true;Lossy=$false}
            $kept=New-OPumper2Result -Completion $native -ExcerptLines 0
            $kept.Data.Rich | Should -Be 1
            $kept.Error.Code | Should -Be 'NativeFailed'
            $kept.Capture.Stdout | Should -Be 'out'
            $kept.Presentation.ExcerptLines | Should -Be 0
            $replaced=New-OPumper2Result -Completion $native -Data @{Other=2}
            $replaced.Data.Other | Should -Be 2
            $native.Data.Rich | Should -Be 1
            $native.Presentation | Should -BeNullOrEmpty
            $task=Invoke-OPumper2Task -AsObject -ScriptBlock { New-OPumper2Result -Completion (New-OP2Completion -Outcome Failed) | Out-Null; 'body' }
            $task.Outcome | Should -Be 'Success'
            {New-OPumper2Result -Completion ([pscustomobject]@{Kind='Other'})} | Should -Throw '*completion object is required*'
            {New-OPumper2Result -Completion ([pscustomobject]@{Value=1})} | Should -Throw '*completion object is required*'
        }
    }
    It 'describes an error by code, phase, exception type and message' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $plain=New-OP2Error 'RouteNotFound' 'Routing'
            $plain.Code | Should -Be 'RouteNotFound'
            $plain.Phase | Should -Be 'Routing'
            $null -eq $plain.ExceptionType -and $null -eq $plain.Message | Should -BeTrue
            $thrown=New-OP2Error 'HandlerFailed' 'Routing' ([InvalidOperationException]::new('handler detail'))
            $thrown.ExceptionType | Should -Be 'System.InvalidOperationException'
            $thrown.Message | Should -BeExactly 'handler detail'
        }
    }
}
