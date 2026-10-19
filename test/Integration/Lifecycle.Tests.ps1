BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Owned process lifecycle' {
    It 'terminates the entire owned tree after a decoder failure' {
        $pidFile=Join-Path $TestDrive 'owned-pids.json'
        $code='$path=' + "'$($pidFile.Replace("'","''"))';" + '$info=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if($IsWindows){"pwsh.exe"}else{"pwsh"})));$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.ArgumentList.Add("-NoProfile");$info.ArgumentList.Add("-NonInteractive");$info.ArgumentList.Add("-Command");$info.ArgumentList.Add("Start-Sleep -Seconds 30");$child=[Diagnostics.Process]::Start($info);[IO.File]::WriteAllText($path,(@($PID,$child.Id)|ConvertTo-Json -Compress));[Console]::OpenStandardOutput().WriteByte(255);Start-Sleep -Seconds 3'
        $owned=@()
        try {
            $result=@(Invoke-TestChild $code @{})[-1]
            $result.Error.Code | Should -Be 'ExecutionFailed'
            $owned=Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
            foreach($processId in $owned) {
                $alive=$false
                $process=Get-Process -Id $processId -ErrorAction SilentlyContinue
                if($process) {
                    $alive=!$process.HasExited
                    if(!$IsWindows -and (Test-Path "/proc/$processId/stat")) {
                        $alive=$alive -and ((Get-Content "/proc/$processId/stat" -Raw) -notmatch '\) Z ')
                    }
                    $process.Dispose()
                }
                $alive | Should -BeFalse
            }
        } finally {
            foreach($processId in $owned) {
                $process=Get-Process -Id $processId -ErrorAction SilentlyContinue
                if($process) {try {if(!$process.HasExited){$process.Kill($true)}} catch {} finally {$process.Dispose()}}
            }
        }
    }
    It 'returns after the timeout grace period while an orphaned process keeps the pipes open' {
        $pidFile=Join-Path $TestDrive 'orphan.pid'
        # The child starts an unredirected grandchild, which inherits the captured pipes, then exits: the grandchild
        # is outside the tree that termination can find, and it keeps both streams open.
        $code='$info=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if($IsWindows){"pwsh.exe"}else{"pwsh"})));$info.UseShellExecute=$false;foreach($a in @("-NoProfile","-NonInteractive","-Command","Start-Sleep -Seconds 60")){$info.ArgumentList.Add($a)};$orphan=[Diagnostics.Process]::Start($info);[IO.File]::WriteAllText(' + "'$($pidFile.Replace("'","''"))'" + ',[string]$orphan.Id);[Console]::Out.Write("parent done")'
        try {
            $watch=[Diagnostics.Stopwatch]::StartNew()
            # The child must start its grandchild and write before the deadline even when mutation workers saturate the CPU.
            $result=@(Invoke-TestChild $code @{TimeoutSeconds=5})[-1]
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
            $result.Outcome | Should -Be 'Timeout'
            $result.Completeness.Source | Should -BeFalse
            $result.Capture.Stdout | Should -BeExactly 'parent done'
            Get-Process -Id ([int](Get-Content -LiteralPath $pidFile)) -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        } finally {
            if (Test-Path -LiteralPath $pidFile) { Stop-Process -Id ([int](Get-Content -LiteralPath $pidFile)) -Force -ErrorAction SilentlyContinue }
        }
    }
    It 'initializes native measurement dependencies in a fresh PowerShell process' {
        $manifest=Join-Path $script:OP2TestRoot 'FrenchExDev.OPumper2.PoSh.psd1'
        $code='Import-Module ' + "'$($manifest.Replace("'","''"))' -DisableNameChecking;" + '$result=Pump-Me (Join-Path $PSHOME $(if($IsWindows){"pwsh.exe"}else{"pwsh"})) -ArgumentList @("-NoProfile","-NonInteractive","-Command","[Console]::Out.Write(42)") -OnRecord {} -AsObject;[Console]::Out.Write($result.Measurement.Status)'
        $state=@{Text=[Text.StringBuilder]::new()}
        # A child process has no runspace substitute: its measurement paths go through its own environment.
        $result=@(Invoke-TestChild $code @{State=$state;Environment=(Get-TestEnvironment);OnStdOut={param($line,$s)[void]$s.Text.Append($line)}})[-1]
        $result.Outcome | Should -Be 'Success'
        $state.Text.ToString() | Should -Be 'SourceMeasured'
    }
}
