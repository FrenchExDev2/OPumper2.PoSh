BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

Describe 'Native execution' {
    # First on purpose: it kills read-loop mutants that block synchronously within seconds, before the stdin tests can deadlock on them under load.
    It 'terminates timeout and cancellation without relaunch' {
        $timeout=@(Invoke-TestChild 'Start-Sleep -Seconds 10' @{TimeoutSeconds=1;Complete={throw 'finalizer'}})[-1]
        $timeout.Outcome | Should -Be 'Timeout'
        $timeout.Error.Code | Should -Be 'Timeout'
        $timeout.Execution.FinalizerError.Code | Should -Be 'FinalizerFailed'
        $timeout.Completeness.Source | Should -BeFalse
        $cancel=[Threading.CancellationTokenSource]::new()
        try {
            $cancel.Cancel()
            $sentinel=Join-Path $TestDrive 'cancelled-child-must-not-start'
            $code='[IO.File]::WriteAllText(' + "'$($sentinel.Replace("'","''"))','started')"
            $cancelled=@(Invoke-TestChild $code @{CancellationToken=$cancel.Token})[-1]
            $cancelled.Outcome | Should -Be 'Cancelled'
            $cancelled.Execution.ExitCode | Should -BeNullOrEmpty
            Test-Path -LiteralPath $sentinel | Should -BeFalse
        } finally {$cancel.Dispose()}
        $running=[Threading.CancellationTokenSource]::new()
        try {
            $result=@(Invoke-TestChild '[Console]::Out.WriteLine("ready");Start-Sleep -Seconds 10' @{CancellationToken=$running.Token;State=$running;OnRecord={param($record,$s)$s.Cancel()}})[-1]
            $result.Outcome | Should -Be 'Cancelled'
            $result.Error.Code | Should -Be 'Cancelled'
            $result.Completeness.Source | Should -BeFalse
        } finally {$running.Dispose()}
    }
    It 'measures captured transport content with independent exact-token fixtures' {
        $result=@(Invoke-TestChild '[Console]::Out.Write("hello world");[Console]::Error.Write("hello world")')[-1]
        $result.Outcome | Should -Be 'Success'
        $result.Measurement.Status | Should -Be 'SourceMeasured'
        $result.Measurement.SourceBytes | Should -Be 22
        $result.Measurement.SourceTokens | Should -Be 4
    }
    It 'dispatches both streams and emits a final projection' {
        $state=@{Out=0;Err=0}
        $values=@(Invoke-TestChild '[Console]::Out.WriteLine("abc");[Console]::Error.WriteLine("xyz")' @{
            State=$state;OnStdOut={param($line,$s)$s.Out++;[pscustomobject]@{Length=$line.Length}};OnStdErr={param($line,$s)$s.Err++}
            Complete={param($s,$e)@{Out=$s.Out;Err=$s.Err;Code=$e.ExitCode}}
        })
        $values.Count | Should -Be 2
        $values[0].Length | Should -Be 3
        $values[-1].Outcome | Should -Be 'Success'
        $values[-1].Data.Out | Should -Be 1
        $values[-1].Data.Err | Should -Be 1
        $values[-1].Execution.StdoutBytes | Should -BeGreaterThan 3
        $values[-1].Measurement.Status | Should -Be 'SourceMeasured'
        $values[-1].Execution.Records | Should -Be 2
        $values[-1].Measurement.SourceBytes | Should -Be ($values[-1].Execution.StdoutBytes+$values[-1].Execution.StderrBytes)
    }
    It 'hands a batch callback every record in order, both streams, and refuses it with another callback' {
        $state=@{Calls=0;Texts=[Collections.Generic.List[string]]::new()}
        $result=@(Invoke-TestChild '1..500 | ForEach-Object { [Console]::Out.WriteLine("o$_") }; [Console]::Error.WriteLine("e")' @{
            State=$state;OnBatch={param($records,$s)$s.Calls++;foreach($r in $records){$s.Texts.Add("$($r.Stream):$($r.Text)")}}
            Complete={param($s,$e)$s.Texts.Count}
        })[-1]
        "$($result.Outcome)|$($result.Data)|$($result.Execution.Records)" | Should -BeExactly 'Success|501|501'
        # Batches, not records: far fewer calls than records.
        $state.Calls | Should -BeLessThan 501
        (@($state.Texts | Where-Object { $_ -like 'stdout:*' }) -join ',') | Should -BeExactly ((1..500 | ForEach-Object { "stdout:o$_" }) -join ',')
        $state.Texts | Should -Contain 'stderr:e'
        { Pump-Me pwsh -OnBatch {} -OnRecord {} -AsObject } | Should -Throw -ErrorId 'AmbiguousParameterSet*'
    }
    It 'keeps reading ignored streams and large records' {
        $state=@{Count=0}
        $result=@(Invoke-TestChild '1..100 | ForEach-Object {[Console]::Out.WriteLine("x");[Console]::Error.WriteLine("ignored")}' @{State=$state;OnStdOut={param($line,$s)$s.Count++}})[-1]
        $result.Outcome | Should -Be 'Success'
        $state.Count | Should -Be 100
        $result.Execution.StderrBytes | Should -BeGreaterThan 600
        $oversized=@(Invoke-TestChild '[Console]::Out.WriteLine("x"*100)' @{MaxRecordCharacters=10})[-1]
        $oversized.Error.Code | Should -Be 'RecordLimit'
        $oversized.Truncation.OmittedRecords | Should -Be 1
        $oversized.Truncation.Applied | Should -BeTrue
        $oversized.Completeness.Source | Should -BeTrue
        $oversized.Completeness.Analysis | Should -BeFalse
    }
    It 'handles NUL framing, trailing records, unicode and stdin' {
        $state=@{Values=[Collections.Generic.List[string]]::new()}
        $result=@(Invoke-TestChild '[Console]::Out.Write("é"+[char]0+"z")' @{State=$state;StdOutDelimiter=[char]0;OnRecord={param($r,$s)$s.Values.Add($r.Text)}})[-1]
        $state.Values.ToArray() | Should -Be @('é','z')
        $result.Execution.StdoutBytes | Should -Be 4
        $inputState=@{Value=$null}
        $inputResult=@(Invoke-TestChild '[Console]::Out.WriteLine([Console]::In.ReadToEnd())' @{InputText='input';State=$inputState;OnStdOut={param($line,$s)$s.Value=$line}})[-1]
        $inputResult.Outcome | Should -Be 'Success'
        $inputState.Value | Should -Be 'input'
        # Input text reaches a child that reads UTF-8 intact, whatever the console code page.
        $accented=@{Value=$null}
        $null=Invoke-TestChild '[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);[Console]::Out.WriteLine([Console]::In.ReadToEnd())' @{InputText='café';State=$accented;OnStdOut={param($line,$s)$s.Value=$line}}
        $accented.Value | Should -BeExactly 'café'
    }
    It 'scopes environment and working directory to the child' {
        $state=@{Values=[Collections.Generic.List[string]]::new()}
        # A run-unique name: parallel workers share this process environment.
        $name='OP2_TEST_PARENT_'+[guid]::NewGuid().ToString('N')
        [Environment]::SetEnvironmentVariable($name,'parent')
        try {
            $result=@(Invoke-TestChild ("[Console]::Out.WriteLine(`$env:$name);[Console]::Out.WriteLine((Get-Location).Path)") @{WorkingDirectory=$TestDrive;Environment=@{$name='child'};State=$state;OnStdOut={param($line,$s)$s.Values.Add($line)}})[-1]
            $result.Outcome | Should -Be 'Success'
            $state.Values[0] | Should -Be 'child'
            $state.Values[1] | Should -Be $TestDrive
            [Environment]::GetEnvironmentVariable($name) | Should -Be 'parent'
            $nullResult=@(Invoke-TestChild "if(`$env:$name){exit 3}" @{Environment=@{$name=$null}})[-1]
            $nullResult.Outcome | Should -Be 'Success'
        } finally { [Environment]::SetEnvironmentVariable($name,$null) }
    }
    It 'distinguishes native failure, accepted codes, parser and finalizer failures' {
        (@(Invoke-TestChild 'exit 7')[-1]).Error.Code | Should -Be 'NativeFailed'
        (@(Invoke-TestChild 'exit 7' @{SuccessExitCodes=@(0,7)})[-1]).Outcome | Should -Be 'Success'
        $parse=@(Invoke-TestChild '[Console]::Out.WriteLine("x")' @{OnRecord={throw 'parser'}})[-1]
        $parse.Error.Code | Should -Be 'CallbackFailed'
        $parse.Completeness.Source | Should -BeTrue
        $parse.Completeness.Analysis | Should -BeFalse
        $final=@(Invoke-TestChild 'exit 0' @{Complete={throw 'finalizer'}})[-1]
        $final.Error.Code | Should -Be 'FinalizerFailed'
        $final.Completeness.Analysis | Should -BeFalse
        $both=@(Invoke-TestChild 'exit 7' @{Complete={throw 'finalizer'}})[-1]
        $both.Error.Code | Should -Be 'NativeFailed'
        $both.Execution.FinalizerError.Code | Should -Be 'FinalizerFailed'
        $both.Completeness.Analysis | Should -BeFalse
        (@(Pump-Me 'missing-op2-binary' -OnRecord {} -AsObject)[-1]).Error.Code | Should -Be 'ExecutionFailed'
        (@(Pump-Me 'missing-op2-binary' -OnRecord {} -AsObject)[-1]).Execution.ExitCode | Should -BeNullOrEmpty
    }
    It 'keeps the complete decoded output of every call on the local object' {
        $fine=@(Invoke-TestChild '[Console]::Out.Write("fine");[Console]::Error.Write("note")')[-1]
        $fine.Outcome | Should -Be 'Success'
        $fine.Capture.Stdout | Should -BeExactly 'fine'
        $fine.Capture.Stderr | Should -BeExactly 'note'
        $fine.Capture.Complete | Should -BeTrue
        $failed=@(Invoke-TestChild '[Console]::Out.Write("one`ntwo é`n");[Console]::Error.Write("broken");exit 5')[-1]
        $failed.Error.Code | Should -Be 'NativeFailed'
        $failed.Capture.Stdout | Should -BeExactly "one`ntwo é`n"
        $failed.Capture.Stderr | Should -BeExactly 'broken'
        $failed.Capture.Complete | Should -BeTrue
        $failed.Capture.Lossy | Should -BeFalse
        $parse=@(Invoke-TestChild '[Console]::Out.Write("a`nb`nc")' @{OnRecord={throw 'parser'}})[-1]
        $parse.Capture.Stdout | Should -BeExactly "a`nb`nc"
        $oversized=@(Invoke-TestChild '[Console]::Out.Write("x"*100)' @{MaxRecordCharacters=10})[-1]
        $oversized.Capture.Stdout | Should -BeExactly ('x'*100)
        # The child must start and write before the deadline even when mutation workers saturate the CPU.
        $timeout=@(Invoke-TestChild '[Console]::Out.Write("before");[Console]::Out.Flush();Start-Sleep -Seconds 15' @{TimeoutSeconds=5})[-1]
        $timeout.Outcome | Should -Be 'Timeout'
        $timeout.Capture.Stdout | Should -BeExactly 'before'
        $timeout.Capture.Complete | Should -BeFalse
        $invalid=@(Invoke-TestChild '[Console]::Out.Write("ok");[Console]::Out.Flush();[Console]::OpenStandardOutput().WriteByte(195)')[-1]
        $invalid.Error.Code | Should -Be 'ExecutionFailed'
        $invalid.Capture.Stdout | Should -BeExactly "ok$([char]0xFFFD)"
        $invalid.Capture.Lossy | Should -BeTrue
        $invalid.Capture.Complete | Should -BeFalse
        $missing=@(Pump-Me 'missing-op2-binary' -OnRecord {} -AsObject)[-1]
        $null -eq $missing.Capture.Stdout -and $null -eq $missing.Capture.Stderr | Should -BeTrue
        $missing.Capture.Complete | Should -BeFalse
    }
    It 'decodes split UTF8, rejects an incomplete codepoint and sends large stdin through EOF' {
        $state=@{Text=[Text.StringBuilder]::new()}
        $code='$stream=[Console]::OpenStandardOutput();$bytes=[Text.Encoding]::UTF8.GetBytes(("x"*8191)+"é");$stream.Write($bytes,0,8192);$stream.Flush();Start-Sleep -Milliseconds 150;$stream.Write($bytes,8192,1)'
        $result=@(Invoke-TestChild $code @{State=$state;OnRecord={param($r,$s)[void]$s.Text.Append($r.Text)}})[-1]
        $result.Outcome | Should -Be 'Success'
        $state.Text.ToString() | Should -Be (('x'*8191)+'é')
        $result.Execution.StdoutBytes | Should -Be 8193
        $invalid=@(Invoke-TestChild '[Console]::OpenStandardOutput().WriteByte(195)')[-1]
        $invalid.Outcome | Should -Be 'Failed'
        $invalid.Error.Code | Should -Be 'ExecutionFailed'
        $invalid.Error.ExceptionType | Should -Be 'System.Text.DecoderFallbackException'
        $unicode=@{Text=[Text.StringBuilder]::new()}
        $encoded=@(Invoke-TestChild '$bytes=[Text.Encoding]::Unicode.GetBytes("éz");[Console]::OpenStandardOutput().Write($bytes,0,$bytes.Length)' @{Encoding='utf-16';State=$unicode;OnStdOut={param($text,$s)[void]$s.Text.Append($text)}})[-1]
        $encoded.Outcome | Should -Be 'Success'
        $unicode.Text.ToString() | Should -Be 'éz'
        $inputState=@{Length=0}
        foreach($inputText in @('',('x'*200000))) {
            $inputResult=@(Invoke-TestChild '[Console]::Out.Write([Console]::In.ReadToEnd().Length)' @{InputText=$inputText;TimeoutSeconds=5;State=$inputState;OnStdOut={param($line,$s)$s.Length=[int]$line}})[-1]
            $inputResult.Outcome | Should -Be 'Success'
            $inputState.Length | Should -Be $inputText.Length
        }
    }
    It 'applies inclusive record and presentation limits at the public boundary' {
        $result=@(Invoke-TestChild '[Console]::Out.Write("x")' @{MaxRecordCharacters=1;MaxItems=0;MaxOutputBytes=256})[-1]
        $result.Outcome | Should -Be 'Success'
        $limit=@(Invoke-TestChild '[Console]::Out.Write("x"*65537)')[-1]
        $limit.Error.Code | Should -Be 'RecordLimit'
    }
    It 'runs the command-line form with native options and delivers failure diagnostics' {
        $echo=Join-Path $TestDrive 'echo-arguments.ps1'
        [IO.File]::WriteAllText($echo,'$args | ForEach-Object { [Console]::Out.WriteLine($_) }')
        $collect={param($record,$state) $record.Text}
        $lines=@(pump -OnRecord $collect -AsObject $script:OP2TestExecutable -NoProfile -NonInteractive -File $echo build -c Release -o out -v q)
        $lines[-1].Outcome | Should -Be 'Success'
        (@($lines | Select-Object -SkipLast 1) -join ' ') | Should -BeExactly 'build -c Release -o out -v q'
        $separated=@(pump -OnRecord $collect -AsObject -- $script:OP2TestExecutable -NoProfile -NonInteractive -File $echo checkout -- main)
        (@($separated | Select-Object -SkipLast 1) -join ' ') | Should -BeExactly 'checkout -- main'
        { pump -OnRecord $collect -AsObject $script:OP2TestExecutable -File $echo checkout -- main } | Should -Throw "*removed the first '--'*"
        $code='[Console]::Out.WriteLine("progress");[Console]::Error.WriteLine("fatal: token=abc");exit 3'
        $failed=(pump -OnRecord {} -AsJson $script:OP2TestExecutable -NoProfile -NonInteractive -Command $code | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
        $failed.Execution.ExitCode | Should -Be 3
        $failed.Error.Code | Should -Be 'NativeFailed'
        ($failed.Excerpt.Stdout.Tail -join '|') | Should -BeExactly 'progress'
        ($failed.Excerpt.Stderr.Tail -join '|') | Should -BeExactly 'fatal: token=[REDACTED]'
        (pump -OnRecord {} -AsJson -ExcerptLines 0 $script:OP2TestExecutable -NoProfile -NonInteractive -Command $code) | Should -Not -Match 'Excerpt|progress'
        $missing=(pump -OnRecord {} -AsJson missing-op2-binary --flag | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
        $missing.Error.Code | Should -Be 'ExecutionFailed'
        $missing.Error.Message | Should -Match 'missing-op2-binary'
        (@($missing.Excerpt.Keys) -join ',') | Should -Be 'Complete'
    }
}
