BeforeAll { . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1') }

class OP2SerializationNode {
    [object]$Child
    [string]$Password='private-fixture'
    OP2SerializationNode([object]$child) {$this.Child=$child}
}

Describe 'Serialization and redaction' {
    It 'protects properties of domain classes and retains well-known scalar types' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Node=[OP2SerializationNode]::new('leaf')} {
            $types=@([guid]::NewGuid(),[DateTimeOffset]::Parse('2026-10-15T12:00:00Z'),[TimeSpan]::FromSeconds(42),[Numerics.BigInteger]::Parse('123456789012345678901234567890'),[datetime]::Parse('2026-10-15'),[decimal]42.5)
            foreach($value in $types) {
                $protected=Protect-OP2Value $value
                $protected.GetType() | Should -Be $value.GetType()
                $protected | Should -Be $value
            }
            $protected=Protect-OP2Value $Node
            $protected.Password | Should -Be '[REDACTED]'
            $protected.Child | Should -Be 'leaf'
        }
        $node=[OP2SerializationNode]::new('leaf')
        1..40 | ForEach-Object {$node=[OP2SerializationNode]::new($node)}
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Node=$node} {
            $result=ConvertTo-OPumper2Output @((New-OP2Completion -Data $Node)) -Format json | ConvertFrom-Json -NoEnumerate
            $result[0].Truncation.Reasons | Should -Contain 'DepthLimit'
        }
    }
    It 'retains array records and exact omission metadata' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $array=[object[]]@(1,2)
            $values=[object[]]::new(2);$values[0]=$array;$values[1]=New-OP2Completion
            $objects=@(ConvertTo-OPumper2Output $values -Format object)
            $objects.Count | Should -Be 2
            [object]::ReferenceEquals($objects[0],$array) | Should -BeTrue
            $records=@(1,2,3,(New-OP2Completion))
            $limited=ConvertTo-OPumper2Output $records -Format json -MaxItems 2 | ConvertFrom-Json -NoEnumerate
            $limited.Count | Should -Be 3
            $limited[-1].Truncation.Applied | Should -BeTrue
            $limited[-1].Truncation.Reasons | Should -Contain 'ItemLimit'
            $limited[-1].Truncation.OmittedRecords | Should -Be 1
            $intact=ConvertTo-OPumper2Output @((New-OP2Completion)) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate
            $intact[0].ContainsKey('Truncation') | Should -BeFalse
            # NotDelivered, the initial measurement status, is omitted like every default; an empty message as well.
            $intact[0].ContainsKey('Measurement') | Should -BeFalse
            $measured=New-OP2Completion -Outcome Failed -ErrorInfo @{Code='Fixture';Phase='Test';ExceptionType=$null;Message=''}
            $measured.Measurement.Status='SourceMeasured'
            $delivered=(ConvertTo-OPumper2Output @($measured) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
            $delivered.Measurement.Status | Should -BeExactly 'SourceMeasured'
            (@($delivered.Error.Keys | Sort-Object) -join ',') | Should -BeExactly 'Code,Phase'
        }
    }
    It 'enforces the recursive depth boundary for dictionaries and arrays' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            foreach($array in @($false,$true)) {
                $value='leaf'
                1..30 | ForEach-Object {if($array){$next=[object[]]::new(1);$next[0]=$value;$value=$next}else{$value=@{Child=$value}}}
                $protected=Protect-OP2Value $value
                1..30 | ForEach-Object {if($array){$protected=$protected[0]}else{$protected=$protected.Child}}
                $protected | Should -Be 'leaf'
                if($array){$next=[object[]]::new(1);$next[0]=$value;$value=$next}else{$value=@{Child=$value}}
                $protected=Protect-OP2Value $value
                1..31 | ForEach-Object {if($array){$protected=$protected[0]}else{$protected=$protected.Child}}
                $protected | Should -Be '[DEPTH LIMIT]'
            }
        }
    }
    It 'reports depth clipping and item removal due solely to the byte budget' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $data=@{Value='leaf'}
            1..35 | ForEach-Object {$data=@{Child=$data}}
            $output=ConvertTo-OPumper2Output @((New-OP2Completion -Data $data)) -Format json | ConvertFrom-Json -NoEnumerate
            $output[0].Truncation.Applied | Should -BeTrue
            ($output[0].Truncation.Reasons -join ',') | Should -Be 'DepthLimit'
            $output[0].Truncation.PSObject.Properties['OmittedRecords'] | Should -BeNullOrEmpty
            $result=New-OP2Completion
            $base=ConvertTo-OP2Text @((Protect-OP2Value $result)) json
            $budget=[Text.Encoding]::UTF8.GetByteCount($base)+300
            $text=ConvertTo-OPumper2Output @(@{Text=('x'*2000)},$result) -Format json -MaxOutputBytes $budget
            $clipped=$text | ConvertFrom-Json -NoEnumerate
            $clipped.Count | Should -Be 1
            $clipped[0].Truncation.Applied | Should -BeTrue
            $clipped[0].Truncation.Reasons | Should -Contain 'OutputLimit'
            $clipped[0].Truncation.OmittedRecords | Should -Be 1
            $text=ConvertTo-OPumper2Output @((New-OP2Completion -Data @{Text=('x'*5000)})) -Format json -MaxOutputBytes 700
            $projection=$text | ConvertFrom-Json -NoEnumerate
            $projection[0].PSObject.Properties['Data'] | Should -BeNullOrEmpty
            $projection[0].Truncation.Applied | Should -BeTrue
            ($projection[0].Truncation.Reasons -join ',') | Should -Be 'DataLimit'
            $projection[0].Truncation.PSObject.Properties['OmittedRecords'] | Should -BeNullOrEmpty
        }
    }
    It 'delivers a masked excerpt of a failure capture, never the capture itself' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $failed=New-OP2Completion -Outcome Failed -Data @{Capture='projected';Note='token=hidden'}
            $failed.Capture=@{Stdout="first-line`r`ntwo`r`npassword=secret`r`n";Stderr='raw diagnostic';Complete=$true;Lossy=$false}
            foreach($format in @('json','yaml')) {
                $text=ConvertTo-OPumper2Output @([pscustomobject]@{Capture='record'},$failed) -Format $format -ExcerptLines 2
                $text | Should -Not -Match 'secret|first-line|hidden'
                $text | Should -Match 'projected'
                $text | Should -Match 'record'
            }
            $parsed=ConvertTo-OPumper2Output @($failed) -Format json -ExcerptLines 2 | ConvertFrom-Json -AsHashtable -NoEnumerate
            $parsed[0].ContainsKey('Capture') | Should -BeFalse
            $parsed[0].Data.Note | Should -Be 'token=[REDACTED]'
            $parsed[0].Excerpt.Stdout.Lines | Should -Be 3
            ($parsed[0].Excerpt.Stdout.Tail -join '|') | Should -BeExactly 'two|password=[REDACTED]'
            $parsed[0].Excerpt.Stderr.Lines | Should -Be 1
            ($parsed[0].Excerpt.Stderr.Tail -join '|') | Should -BeExactly 'raw diagnostic'
            $parsed[0].Excerpt.ContainsKey('Complete') | Should -BeFalse
            $parsed[0].Excerpt.ContainsKey('Lossy') | Should -BeFalse
            $parsed[0].ContainsKey('Truncation') | Should -BeFalse
            $failed.Capture.Stdout | Should -Match 'password=secret'
            @(ConvertTo-OPumper2Output @($failed) -Format object)[0].Capture.Stderr | Should -Be 'raw diagnostic'
            # The configured window applies when none is given; zero disables the excerpt.
            (ConvertTo-OPumper2Output @($failed) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Excerpt.Stdout.Tail.Count | Should -Be 3
            $config=Get-OP2Configuration
            $config.ExcerptLines=1
            $failed.Capture=@{Stdout=$null;Stderr="first`nlast";Complete=$false;Lossy=$true}
            $parsed=ConvertTo-OPumper2Output @($failed) -Format json -Configuration $config | ConvertFrom-Json -AsHashtable -NoEnumerate
            $parsed[0].Excerpt.ContainsKey('Stdout') | Should -BeFalse
            ($parsed[0].Excerpt.Stderr.Tail -join '|') | Should -BeExactly 'last'
            $parsed[0].Excerpt.Complete | Should -BeFalse
            $parsed[0].Excerpt.Lossy | Should -BeTrue
            $parsed=ConvertTo-OPumper2Output @($failed) -Format json -ExcerptLines 0 | ConvertFrom-Json -AsHashtable -NoEnumerate
            $parsed[0].ContainsKey('Excerpt') | Should -BeFalse
            $failed.Capture=@{Stdout="`r`n";Stderr='';Complete=$false;Lossy=$false}
            ((ConvertTo-OPumper2Output @($failed) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Excerpt.Keys -join ',') | Should -Be 'Complete'
        }
    }
    It 'keeps a successful capture local and delivers no excerpt for it' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $success=New-OP2Completion -Data @{Value=1}
            $success.Capture=@{Stdout="out`n";Stderr='err';Complete=$true;Lossy=$false}
            $parsed=ConvertTo-OPumper2Output @($success) -Format json -ExcerptLines 5 | ConvertFrom-Json -AsHashtable -NoEnumerate
            $parsed[0].ContainsKey('Excerpt') | Should -BeFalse
            $parsed[0].ContainsKey('Capture') | Should -BeFalse
            @(ConvertTo-OPumper2Output @($success) -Format object)[0].Capture.Stdout | Should -BeExactly "out`n"
        }
    }
    It 'delivers the projection of a result and keeps its complete Data local' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $native=New-OP2Completion -Outcome Failed -Data @{Rows=@(1,2,3);Note='token=hidden'}
            $native.Capture=@{Stdout="one`ntwo`nthree";Stderr=$null;Complete=$true;Lossy=$false}
            $seen=@{}
            $projection={param($data,$settings) $seen.Settings=$settings; @{Count=$data.Rows.Count;Note=$data.Note}}.GetNewClosure()
            $result=New-OPumper2Result -Completion $native -Projection $projection
            [object]::ReferenceEquals($result,$native) | Should -BeFalse
            $native.PSObject.Properties['Presentation'].Value | Should -BeNullOrEmpty
            $parsed=ConvertTo-OPumper2Output @($result) -Format json -MaxItems 7 -MaxOutputBytes 4096 -ExcerptLines 2 | ConvertFrom-Json -AsHashtable -NoEnumerate
            $parsed[0].Data.Count | Should -Be 3
            $parsed[0].Data.Note | Should -Be 'token=[REDACTED]'
            $parsed[0].ContainsKey('Presentation') | Should -BeFalse
            ($parsed[0].Excerpt.Stdout.Tail -join '|') | Should -BeExactly 'two|three'
            $seen.Settings.Format | Should -Be 'json'
            $seen.Settings.MaxItems | Should -Be 7
            $seen.Settings.MaxOutputBytes | Should -Be 4096
            $seen.Settings.ExcerptLines | Should -Be 2
            $result.Data.Rows.Count | Should -Be 3
            (ConvertTo-OPumper2Output @($result) -Format yaml) | Should -Match 'Count: 3'
            $local=@(ConvertTo-OPumper2Output @($result) -Format object)[0]
            $local.Data.Rows.Count | Should -Be 3
            $local.Capture.Stdout | Should -BeExactly "one`ntwo`nthree"
            $many=New-OPumper2Result -Completion $native -Projection {param($data) 'a';'b'}
            ((ConvertTo-OPumper2Output @($many) -Format json | ConvertFrom-Json -NoEnumerate)[0].Data -join ',') | Should -Be 'a,b'
            $none=New-OPumper2Result -Completion $native -Projection {param($data)}
            $empty=(ConvertTo-OPumper2Output @($none) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
            $empty.ContainsKey('Data') | Should -BeFalse
            $empty.ContainsKey('Truncation') | Should -BeFalse
        }
    }
    It 'narrows the excerpt to the window a result declares, never widens it' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $native=New-OP2Completion -Outcome Failed -Data @{Value=1}
            $native.Capture=@{Stdout="a`nb`nc";Stderr=$null;Complete=$true;Lossy=$false}
            $explained=New-OPumper2Result -Completion $native -ExcerptLines 0
            $parsed=ConvertTo-OPumper2Output @($explained) -Format json -ExcerptLines 5 | ConvertFrom-Json -AsHashtable -NoEnumerate
            $parsed[0].ContainsKey('Excerpt') | Should -BeFalse
            $parsed[0].Data.Value | Should -Be 1
            $narrow=New-OPumper2Result -Completion $native -ExcerptLines 1
            ((ConvertTo-OPumper2Output @($narrow) -Format json -ExcerptLines 5 | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Excerpt.Stdout.Tail -join '|') | Should -BeExactly 'c'
            $wide=New-OPumper2Result -Completion $native -ExcerptLines 9
            ((ConvertTo-OPumper2Output @($wide) -Format json -ExcerptLines 2 | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Excerpt.Stdout.Tail -join '|') | Should -BeExactly 'b|c'
            $open=New-OPumper2Result -Completion $native -Projection {param($data) @{Projected=$data.Value}}
            ((ConvertTo-OPumper2Output @($open) -Format json -ExcerptLines 2 | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Excerpt.Stdout.Tail -join '|') | Should -BeExactly 'b|c'
        }
    }
    It 'omits the Data of a failing projection and reports it' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            foreach($projection in @({throw 'projection fixture'},{Write-Warning 'fixture'})) {
                $result=New-OPumper2Result -Data @{Value=1} -Projection $projection
                $parsed=ConvertTo-OPumper2Output @($result) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate
                $parsed[0].Outcome | Should -Be 'Success'
                $parsed[0].ContainsKey('Data') | Should -BeFalse
                ($parsed[0].Truncation.Reasons -join ',') | Should -Be 'ProjectionFailed'
                $result.Data.Value | Should -Be 1
            }
        }
    }
    It 'delivers a compact envelope: outcome, Data, exit code, errors, excerpt, truncation and recall' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $config=Get-OP2Configuration; $config.Envelope='compact'
            $failed=New-OP2Completion -Outcome Failed -Data @{Value=1} -Execution @{ExitCode=2;InvocationIds=@('x');ElapsedMs=5;Records=3} -ErrorInfo (New-OP2Error 'NativeFailed' 'Execution')
            $failed.Capture=@{Stdout='tail';Stderr=$null;Complete=$true;Lossy=$false}
            $failed.Measurement.Status='SourceMeasured'
            $delivery=Format-OP2Delivery @(1,2,$failed) json 1 8192 5 $config 'recall-id'
            $parsed=($delivery.Text | ConvertFrom-Json -AsHashtable -NoEnumerate)[-1]
            (@($parsed.Keys) -join ',') | Should -BeExactly 'Kind,Outcome,Data,Execution,Error,Truncation,Excerpt,Recall'
            (@($parsed.Execution.Keys) -join ',') | Should -BeExactly 'ExitCode'
            $parsed.Recall | Should -BeExactly 'recall-id'
            $failed.PSObject.Properties['Recall'] | Should -BeNullOrEmpty
            $quiet=(Format-OP2Delivery @((New-OP2Completion -Data 1)) json 1 8192 5 $config).Text | ConvertFrom-Json -AsHashtable -NoEnumerate
            (@($quiet[0].Keys) -join ',') | Should -BeExactly 'Kind,Outcome,Data'
            $task=New-OP2Completion -Outcome Failed -Execution @{ExitCode=$null;InvocationIds=@();Steps=2;Issues=@([pscustomobject]@{Outcome='Failed';ExitCode=1})}
            (@(((Format-OP2Delivery @($task) yaml 1 8192 0 $config).Text | ConvertFrom-Yaml)[0].Execution.Keys) -join ',') | Should -BeExactly 'Issues'
            $config.MeasureAlternateFormat=$true
            (Get-OP2DeliveryPart $delivery.Document json $config).Alternate | Should -Not -Match 'Measurement|ElapsedMs'
        }
    }
    It 'measures the parts a delivery is made of and its alternate format' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $config=Get-OP2Configuration
            $failed=New-OP2Completion -Outcome Failed -Data @{Value=1}
            $failed.Capture=@{Stdout="one`ntwo";Stderr=$null;Complete=$true;Lossy=$false}
            $document=@('record',(Protect-OP2Value $failed 1 @{ExcerptLines=2;DepthApplied=$false;ObfuscationFailed=$false;ExcerptApplied=$false} -Plain))
            [void](ConvertTo-OP2Text $document json)
            $parts=Get-OP2DeliveryPart $document json $config
            $parts.Data | Should -BeExactly '{"Value":1}'
            $parts.Records | Should -BeExactly '["record"]'
            $parts.Excerpt | Should -BeExactly '{"Stdout":{"Lines":2,"Tail":["one","two"]}}'
            $parts.ContainsKey('Alternate') | Should -BeFalse
            $config.MeasureAlternateFormat=$true
            $yaml=Get-OP2DeliveryPart $document json $config
            $yaml.AlternateFormat | Should -BeExactly 'yaml'
            $yaml.Alternate | Should -Match '^- record'
            $single=@((Protect-OP2Value (New-OP2Completion) 1 @{ExcerptLines=0;DepthApplied=$false;ObfuscationFailed=$false;ExcerptApplied=$false} -Plain))
            [void](ConvertTo-OP2Text $single yaml)
            $bare=Get-OP2DeliveryPart $single yaml $config
            "$($bare.Data)|$($bare.Records)|$($bare.Excerpt)|$($bare.AlternateFormat)" | Should -BeExactly '|||json'
        }
    }
    It 'records each delivery with its origin, format, parts and truncation' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            Mock Save-OP2Delivery {}
            $origin=@{Route='r';Provider='p';Command='c'}
            ConvertTo-OPumper2Output @(1,2,(New-OP2Completion -Data @{Value=1})) -Format json -MaxItems 1 -Origin $origin | Out-Null
            Should -Invoke Save-OP2Delivery -Times 1 -Exactly -ParameterFilter {
                $Format -eq 'json' -and $Origin.Route -eq 'r' -and $Truncation -eq 'ItemLimit' -and $Parts.Records -eq '[1]' -and $Parts.Data -eq '{"Value":1}' -and $Text -match '"Value":1'
            }
            ConvertTo-OPumper2Output @((New-OP2Completion)) -Format yaml | Out-Null
            Should -Invoke Save-OP2Delivery -Times 1 -Exactly -ParameterFilter { $Format -eq 'yaml' -and $Origin.Count -eq 0 -and $Truncation -eq '' }
        }
    }
    It 'cuts long excerpt lines and reports the excerpt limit' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $failed=New-OP2Completion -Outcome Failed
            $failed.Capture=@{Stdout=('a'*1000)+"`n"+'c'+('b'*1000);Stderr=$null;Complete=$true;Lossy=$false}
            $parsed=ConvertTo-OPumper2Output @($failed) -Format json -MaxOutputBytes 100000 | ConvertFrom-Json -AsHashtable -NoEnumerate
            $parsed[0].Excerpt.Stdout.Tail[0] | Should -BeExactly ('a'*1000)
            $parsed[0].Excerpt.Stdout.Tail[1] | Should -BeExactly ('c'+('b'*999)+[char]0x2026)
            $parsed[0].Truncation.Applied | Should -BeTrue
            ($parsed[0].Truncation.Reasons -join ',') | Should -Be 'ExcerptLimit'
        }
    }
    It 'shrinks failure excerpts last, oldest line of the longest tail first' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            # A delivery records its measurement on the completion, so every call converts a fresh one.
            function New-Failed([object]$Capture, [object]$Execution) {
                $completion=New-OP2Completion -Outcome Failed -Execution $Execution
                $completion.Capture=$Capture
                $completion
            }
            function Get-Delivered([scriptblock]$Factory, [int]$Shortfall) {
                $full=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-OPumper2Output @(& $Factory) -Format json))
                (ConvertTo-OPumper2Output @(& $Factory) -Format json -MaxOutputBytes ($full-$Shortfall) | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
            }
            $both={New-Failed @{Stdout=('A'+'o'*99)+"`n"+('B'+'o'*99);Stderr=('C'+'e'*99)+"`n"+('D'+'e'*99);Complete=$true;Lossy=$false}}
            # A delivery of exactly the budget is not shrunk.
            (Get-Delivered $both 0).ContainsKey('Truncation') | Should -BeFalse
            $tie=Get-Delivered $both 1
            ($tie.Excerpt.Stdout.Tail -join '|') | Should -BeExactly ('B'+'o'*99)
            $tie.Excerpt.Stdout.Lines | Should -Be 2
            $tie.Excerpt.Stderr.Tail.Count | Should -Be 2
            ($tie.Truncation.Reasons -join ',') | Should -Be 'ExcerptLimit'
            $longest=Get-Delivered {New-Failed @{Stdout=('A'+'o'*99);Stderr=('C'+'e'*99)+"`n"+('D'+'e'*99);Complete=$true;Lossy=$false}} 1
            $longest.Excerpt.Stdout.Tail.Count | Should -Be 1
            ($longest.Excerpt.Stderr.Tail -join '|') | Should -BeExactly ('D'+'e'*99)
            # Issues carry their own excerpts, which shrink the same way.
            $issueCapture=@{Stdout=$null;Stderr=('C'+'e'*99)+"`n"+('D'+'e'*99);Complete=$true;Lossy=$false}
            $issue=(Get-Delivered {New-Failed $null @{ExitCode=$null;InvocationIds=@();ElapsedMs=1;Issues=@([pscustomobject]@{Outcome='Failed';ExitCode=2;Capture=$issueCapture})}} 1).Execution.Issues[0]
            $issue.ExitCode | Should -Be 2
            ($issue.Excerpt.Stderr.Tail -join '|') | Should -BeExactly ('D'+'e'*99)
            # Records and Data go first; an excerpt that still cannot fit leaves only minimal metadata.
            $failed=New-OP2Completion -Outcome Failed -Data @{Text=('x'*300)}
            $failed.Capture=@{Stdout=('A'+'o'*99)+"`n"+('B'+'o'*99);Stderr=$null;Complete=$true;Lossy=$false}
            $text=ConvertTo-OPumper2Output @(@{Text=('y'*300)},$failed) -Format json -MaxOutputBytes 400
            $parsed=($text | ConvertFrom-Json -AsHashtable -NoEnumerate)
            $parsed.Count | Should -Be 1
            $parsed[0].ContainsKey('Data') | Should -BeFalse
            ($parsed[0].Truncation.Reasons -join ',') | Should -Be 'OutputLimit,DataLimit,ExcerptLimit'
            ($parsed[0].Excerpt.Stdout.Tail -join '|') | Should -BeExactly ('B'+'o'*99)
            $minimal=(ConvertTo-OPumper2Output @($failed) -Format json -MaxOutputBytes 256 | ConvertFrom-Json -AsHashtable -NoEnumerate)[0]
            ($minimal.Truncation.Reasons -join ',') | Should -Be 'MetadataLimit'
            $minimal.ContainsKey('Excerpt') | Should -BeFalse
        }
    }
    It 'omits default engine metadata and never compacts domain data' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $issue=[pscustomobject]@{Outcome='Failed';ExitCode=$null;Analysis=$true;Source=$false;Truncated=$false;Capture=$null}
            $execution=@{ExitCode=0;InvocationIds=@();ElapsedMs=0.5;Records=0;Steps=1;Issues=@($issue)}
            $errorInfo=@{Code='token=visible';Phase='';ExceptionType='System.Exception';Message='bad token=hidden'}
            $completion=New-OP2Completion -Outcome Failed -Data @{Flag=$false;Zero=0;Empty='';Nothing=$null;List=@()} -Execution $execution -ErrorInfo $errorInfo
            $completion.Completeness.Analysis=$true
            $parsed=ConvertTo-OPumper2Output @('record',$completion) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate
            $parsed[0] | Should -Be 'record'
            $final=$parsed[1]
            ($final.Keys -join ',') | Should -Be 'Kind,SchemaVersion,Outcome,Data,Execution,Error,Completeness'
            $final.SchemaVersion | Should -Be 2
            (@($final.Data.Keys | Sort-Object) -join ',') | Should -Be 'Empty,Flag,List,Nothing,Zero'
            (@($final.Execution.Keys | Sort-Object) -join ',') | Should -Be 'ElapsedMs,ExitCode,Issues,Steps'
            $final.Execution.ExitCode | Should -Be 0
            $final.Execution.ElapsedMs | Should -Be 0.5
            $final.Execution.Steps | Should -Be 1
            (@($final.Execution.Issues[0].Keys) -join ',') | Should -Be 'Outcome,Source'
            $final.Execution.Issues[0].Source | Should -BeFalse
            (@($final.Error.Keys | Sort-Object) -join ',') | Should -Be 'Code,ExceptionType,Message'
            $final.Error.Code | Should -Be 'token=visible'
            $final.Error.Message | Should -Be 'bad token=[REDACTED]'
            (@($final.Completeness.Keys) -join ',') | Should -Be 'Source'
            $final.ContainsKey('Measurement') | Should -BeFalse
            $false | Should -Be ((ConvertTo-OPumper2Output @((New-OP2Completion -Data $false)) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Data)
            $object=@(ConvertTo-OPumper2Output @($completion) -Format object)[0]
            $object.Truncation.Applied | Should -BeFalse
            $object.Error.Message | Should -Be 'bad token=hidden'
        }
    }
    It 'accumulates truncation reasons and omissions without duplicates' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $record=@{Text=('x'*300)}
            $base=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-OP2Text @((Protect-OP2Value (New-OP2Completion) -Plain)) json))
            $recordBytes=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $record -Compress))
            $values=@($record,$record,$record,$record,$record,(New-OP2Completion))
            $text=ConvertTo-OPumper2Output $values -Format json -MaxItems 3 -MaxOutputBytes ($base+$recordBytes+150)
            $parsed=$text | ConvertFrom-Json -NoEnumerate
            $parsed.Count | Should -Be 2
            ($parsed[-1].Truncation.Reasons -join ',') | Should -Be 'ItemLimit,OutputLimit'
            $parsed[-1].Truncation.OmittedRecords | Should -Be 4
            $deep=@{Value='leaf'}
            1..35 | ForEach-Object {$deep=@{Child=$deep}}
            $budget=$base+200
            $parsed=ConvertTo-OPumper2Output @($deep,(New-OP2Completion -Data @{Answer=42})) -Format json -MaxOutputBytes $budget | ConvertFrom-Json -NoEnumerate
            $parsed.Count | Should -Be 1
            $parsed[0].Data.Answer | Should -Be 42
            ($parsed[0].Truncation.Reasons -join ',') | Should -Be 'DepthLimit,OutputLimit'
            $parsed[0].Truncation.OmittedRecords | Should -Be 1
            $completion=New-OP2Completion
            Add-OP2Truncation $completion 'ItemLimit' 2
            Add-OP2Truncation $completion 'ItemLimit' 3
            ($completion.Truncation.Reasons -join ',') | Should -Be 'ItemLimit'
            $completion.Truncation.OmittedRecords | Should -Be 5
        }
    }
    It 'obtains serializer policy from a supplied configuration' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $config=Get-OP2Configuration
            $config.MaxItems=0;$config.MaxOutputBytes=256
            $text=ConvertTo-OPumper2Output @(42,(New-OP2Completion -Data @{Text=('x'*1000)})) -Format json -Configuration $config
            [Text.Encoding]::UTF8.GetByteCount($text) | Should -BeLessOrEqual 256
            ($text | ConvertFrom-Json -NoEnumerate).Count | Should -Be 1
        }
    }
    It 'honors default limits, explicit configuration and the exact byte budget' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Directory=$TestDrive} {
            $records=@(1..21)+@(New-OP2Completion)
            $output=ConvertTo-OPumper2Output $records -Format json | ConvertFrom-Json -NoEnumerate
            $output.Count | Should -Be 21
            # Eight invocation identifiers keep the compact metadata above the budget once Data is dropped.
            $ids=@(1..8 | ForEach-Object {[guid]::NewGuid().ToString('N')})
            $completion=New-OP2Completion -Data @{Text=('x'*10000)} -Execution @{ExitCode=$null;InvocationIds=$ids;ElapsedMs=1}
            $text=ConvertTo-OPumper2Output @($completion) -Format json -MaxOutputBytes 256
            $minimal=$text | ConvertFrom-Json -AsHashtable -NoEnumerate
            $minimal[0].Truncation.Applied | Should -BeTrue
            ($minimal[0].Truncation.Reasons -join ',') | Should -Be 'MetadataLimit'
            $minimal[0].ContainsKey('Completeness') | Should -BeFalse
            $minimal[0].ContainsKey('Error') | Should -BeFalse
            $minimal[0].ContainsKey('Execution') | Should -BeFalse
            # Without Data to drop, an oversized envelope goes straight to minimal metadata.
            $bare=ConvertTo-OPumper2Output @((New-OP2Completion -Execution @{ExitCode=$null;InvocationIds=$ids;ElapsedMs=1})) -Format json -MaxOutputBytes 256 | ConvertFrom-Json -AsHashtable -NoEnumerate
            ($bare[0].Truncation.Reasons -join ',') | Should -Be 'MetadataLimit'
            foreach($format in @('json','yaml')) {
                $failure=New-OP2Completion -Outcome Failed -Data @{Text=('x'*10000)} -Execution @{ExitCode=7;InvocationIds=$ids;ElapsedMs=1} -ErrorInfo @{Code='NativeFailed';Phase='Execution'}
                $failedText=ConvertTo-OPumper2Output @($failure) -Format $format -MaxOutputBytes 256
                [Text.Encoding]::UTF8.GetByteCount($failedText) | Should -BeLessOrEqual 256
                $failedText | Should -Match 'NativeFailed'
                $failedText | Should -Match 'false'
                $failedText | Should -Match 'MetadataLimit'
            }
            $config=Get-OP2Configuration
            $config.DatabasePath=Join-Path $Directory 'explicit.sqlite'
            $completion=New-OP2Completion
            ConvertTo-OPumper2Output @($completion) -Format json -Configuration $config | Out-Null
            Test-Path -LiteralPath $config.DatabasePath | Should -BeTrue
        }
    }
    It 'preserves null, empty and nested arrays while redacting secret fields' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $value = [pscustomobject]@{ Empty=@(); Singleton=@(1); Nested=@(@(1,2),@()); Nothing=$null; Password='secret'; Note='token=hidden'; Scalar=42; EmptyObject=[pscustomobject]@{} }
            $result = New-OP2Completion -Data $value
            $text = ConvertTo-OPumper2Output @($result) -Format json
            $parsed = ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate
            $parsed.Count | Should -Be 1
            $parsed[0].Data.Empty.Count | Should -Be 0
            $parsed[0].Data.Singleton.Count | Should -Be 1
            $parsed[0].Data.Nested[1].Count | Should -Be 0
            $parsed[0].Data.Password | Should -Be '[REDACTED]'
            $parsed[0].Data.Note | Should -Be 'token=[REDACTED]'
            $parsed[0].Data.Scalar | Should -Be 42
            $parsed[0].Data.Nothing | Should -BeNullOrEmpty
            $parsed[0].Data.EmptyObject.Count | Should -Be 0
        }
    }
    It 'bounds final UTF8 JSON and YAML while preserving completion' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            foreach ($format in @('json','yaml')) {
                $result = New-OP2Completion -Data @{Text=('é'*4000)}
                $values = @([pscustomobject]@{Text=('x'*500)},[pscustomobject]@{Text=('x'*500)},$result)
                $text = ConvertTo-OPumper2Output $values -Format $format -MaxItems 1 -MaxOutputBytes 400
                [Text.Encoding]::UTF8.GetByteCount($text) | Should -BeLessOrEqual 400
                $text | Should -Match 'Completion'
                $text | Should -Match 'true'
            }
            { ConvertTo-OPumper2Output @() -Format json } | Should -Throw '*completion object*'
            { ConvertTo-OPumper2Output @([pscustomobject]@{Kind='Other'}) -Format json } | Should -Throw '*completion object*'
        }
    }
    It 'does not bound or serialize object output' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $value = [pscustomobject]@{Text=('x'*10000)}
            $result = New-OP2Completion -Data $value
            $objects = @(ConvertTo-OPumper2Output @($value,$result) -Format object -MaxItems 0 -MaxOutputBytes 256)
            [object]::ReferenceEquals($objects[0],$value) | Should -BeTrue
            $objects[1].Data.Text.Length | Should -Be 10000
        }
    }
    It 'compacts the alternate measurement like the delivery and drops an empty compact execution' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $config = Get-OP2Configuration; $config.MeasureAlternateFormat = $true
            $document = { @([ordered]@{ Kind = 'Completion'; SchemaVersion = 2; Outcome = 'Success'; Data = 'x' }) }
            (Get-OP2DeliveryPart (& $document) 'yaml' $config).Alternate | Should -Match '"SchemaVersion"'
            $config.Envelope = 'compact'
            (Get-OP2DeliveryPart (& $document) 'yaml' $config).Alternate | Should -Not -Match 'SchemaVersion'
            (@((Select-OP2CompactEnvelope ([ordered]@{ Kind = 'Completion'; Execution = [ordered]@{ ElapsedMs = 1 } })).Keys) -join ',') | Should -BeExactly 'Kind'
            (Select-OP2CompactEnvelope ([ordered]@{ Kind = 'Completion'; Execution = [ordered]@{ ElapsedMs = 1; ExitCode = 2 } })).Execution.ExitCode | Should -Be 2
        }
    }
    It 'stores no recall and measures no delivery inside a task' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            Mock Save-OP2Recall { 'abc' }
            Mock Save-OP2Delivery {}
            $completion = New-OP2Completion -Data 'x'
            ConvertTo-OPumper2Output @($completion) -Format json | Should -Match '"Recall":"abc"'
            $scope = Enter-OP2Call 0; $scope.Task = @{}
            try { ConvertTo-OPumper2Output @($completion) -Format json | Should -Not -Match 'Recall' }
            finally { Exit-OP2Call $scope }
            Should -Invoke Save-OP2Recall -Times 1 -Exactly
            Should -Invoke Save-OP2Delivery -Times 1 -Exactly
        }
    }
    It 'formats contributor reports by their As* switches, obfuscated and compacted, without measuring them' {
        $report = New-OPumper2Result -Data ([ordered]@{ Note = 'token=abc'; Count = 2 })
        [object]::ReferenceEquals((Format-OPumper2Report $report @{ AsObject = $true }), $report) | Should -BeTrue
        $json = (Format-OPumper2Report $report @{ AsJson = $true }) | ConvertFrom-Json -AsHashtable -NoEnumerate
        "$($json[0].Data.Note)|$($json[0].Data.Count)|$($json[0].ContainsKey('Presentation'))" | Should -BeExactly 'token=[REDACTED]|2|False'
        (Format-OPumper2Report $report) | Should -Match '(?m)^- Kind: Completion\r?$'
        { Format-OPumper2Report $report @{ AsText = $true } } | Should -Throw '*Unsupported report format: text.*'
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Report = $report; Directory = $TestDrive } {
            $path = Join-Path $Directory 'report-compact.yaml'
            [IO.File]::WriteAllText($path, "general:`n  envelope: compact")
            $previous = $script:OP2Environment.OPUMPER2_CONFIG_PATH
            try {
                $script:OP2Environment.OPUMPER2_CONFIG_PATH = $path
                $compact = (Format-OPumper2Report $Report @{ AsJson = $true }) | ConvertFrom-Json -AsHashtable -NoEnumerate
                $compact[0].ContainsKey('SchemaVersion') | Should -BeFalse
            } finally { $script:OP2Environment.OPUMPER2_CONFIG_PATH = $previous }
            $full = (Format-OPumper2Report $Report @{ AsJson = $true }) | ConvertFrom-Json -AsHashtable -NoEnumerate
            $full[0].ContainsKey('SchemaVersion') | Should -BeTrue
        }
    }
    It 'delivers a kept completion from the pipeline as pump would, never its capture' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            Mock Save-OP2Recall { 'abc' }
            Mock Save-OP2Delivery {}
            $failed = New-OP2Completion -Outcome Failed -Data @{ Note = 'token=hidden' }
            $failed.Capture = @{ Stdout = "one`ntwo`npassword=secret`n"; Stderr = $null; Complete = $true; Lossy = $false }
            $kept = @([pscustomobject]@{ Line = 'first' }, [pscustomobject]@{ Line = 'second' }, $failed)
            $kept | Out-OPumper2 -AsJson | Should -BeExactly (ConvertTo-OPumper2Output $kept -Format json)
            $kept | Out-OPumper2 -AsYaml | Should -BeExactly (ConvertTo-OPumper2Output $kept -Format yaml)
            $text = $kept | Out-OPumper2 -AsJson
            $text | Should -Not -Match 'secret|hidden'
            $text | Should -Match '"Recall":"abc"'
            # Each limit given reaches the delivery.
            $parsed = $kept | Out-OPumper2 -AsJson -MaxItems 1 -ExcerptLines 1 | ConvertFrom-Json -AsHashtable -NoEnumerate
            "$($parsed.Count)|$($parsed[0].Line)|$($parsed[1].Truncation.OmittedRecords)|$($parsed[1].Excerpt.Stdout.Tail -join ',')" | Should -BeExactly '2|first|1|password=[REDACTED]'
            $failed.Data = @{ Rows = @(1..2000) }
            ($failed | Out-OPumper2 -AsJson -MaxOutputBytes 2048 | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Truncation.Reasons | Should -Contain 'DataLimit'
            Should -Invoke Save-OP2Delivery -Times 7 -Exactly
        }
    }
    It 'wraps other pipeline values in a successful result and delivers text even when objects are configured' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Directory = $TestDrive } {
            Mock Save-OP2Recall {}
            Mock Save-OP2Delivery {}
            $one = 'a' | Out-OPumper2 -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate
            "$($one[0].Outcome)|$($one[0].Data)|$($one[0].Data -is [string])" | Should -BeExactly 'Success|a|True'
            $many = @(1, 2, 3) | Out-OPumper2 -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate
            ($many[0].Data -join ',') | Should -BeExactly '1,2,3'
            ((@('x', 'y') | Out-OPumper2 -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Data -join ',') | Should -BeExactly 'x,y'
            # A single array value stays that array.
            ((, @(4, 5)) | Out-OPumper2 -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Data.Count | Should -Be 2
            $many.Count | Should -Be 1
            $none = @() | Out-OPumper2 -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate
            "$($none[0].Outcome)|$($null -eq $none[0]['Data'])" | Should -BeExactly 'Success|True'
            Out-OPumper2 -InputObject @{ Note = 'token=abc' } | Should -Match '(?m)^- Kind: Completion\r?$'
            { 'a' | Out-OPumper2 -AsJson -AsYaml } | Should -Throw '*mutually exclusive*'
            # Only a completion ends the values: another Kind is data.
            ([pscustomobject]@{ Kind = 'Record' } | Out-OPumper2 -AsJson | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Data.Kind | Should -Be 'Record'
            # The lowest limits are accepted.
            (@(1, 2) | Out-OPumper2 -AsJson -MaxItems 0 -ExcerptLines 0 -MaxOutputBytes 256 | ConvertFrom-Json -AsHashtable -NoEnumerate)[0].Outcome | Should -Be 'Success'
            $path = Join-Path $Directory 'out-object.yaml'
            [IO.File]::WriteAllText($path, "general:`n  outputFormat: object")
            $previous = $script:OP2Environment.OPUMPER2_CONFIG_PATH
            try {
                $script:OP2Environment.OPUMPER2_CONFIG_PATH = $path
                'a' | Out-OPumper2 | Should -Match '(?m)^  Data: a\r?$'
                [IO.File]::WriteAllText($path, "general:`n  outputFormat: json")
                'a' | Out-OPumper2 | Should -Match '"Data":"a"'
            } finally { $script:OP2Environment.OPUMPER2_CONFIG_PATH = $previous }
        }
    }
    It 'delivers dictionary entries named like dictionary members' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            foreach ($data in @(@{ Count = 5; Keys = 'k'; Values = @(1, 2) }, [ordered]@{ Count = 5; Keys = 'k'; Values = @(1, 2) })) {
                $parsed = ConvertTo-OPumper2Output @(New-OP2Completion -Data $data) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate
                "$($parsed[0].Data['Count'])|$($parsed[0].Data['Keys'])|$($parsed[0].Data['Values'] -join ',')" | Should -BeExactly '5|k|1,2'
            }
        }
    }
    It 'names the dependency script when powershell-yaml is missing' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Directory = $TestDrive } {
            $saved = $script:OP2YamlSerializer; $assemblies = $script:OP2YamlAssemblies
            try {
                $script:OP2YamlSerializer = $null; $script:OP2YamlAssemblies = $null
                Mock Get-OP2YamlLibrary { throw 'powershell-yaml 0.4.12 is required: run build/Initialize-Dependencies.ps1 -Tools.' }
                { Get-OP2YamlSerializer } | Should -Throw '*powershell-yaml 0.4.12 is required*Initialize-Dependencies.ps1 -Tools*'
            } finally { $script:OP2YamlSerializer = $saved; $script:OP2YamlAssemblies = $assemblies }
        }
    }
    It 'finds powershell-yaml by its pinned path under each module root in order' {
        InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{ Directory = $TestDrive } {
            { Get-OP2YamlLibrary -ModuleRoot @((Join-Path $Directory 'none')) } | Should -Throw '*powershell-yaml 0.4.12 is required*'
            $found = Join-Path $Directory 'modules/powershell-yaml/0.4.12/lib/netstandard2.1'
            [void][IO.Directory]::CreateDirectory($found); [IO.File]::WriteAllText((Join-Path $found 'YamlDotNet.dll'), '')
            Get-OP2YamlLibrary -ModuleRoot @((Join-Path $Directory 'none'), (Join-Path $Directory 'modules')) | Should -BeExactly $found
        }
    }
    It 'reads YAML exactly as ConvertFrom-Yaml does, types included, without importing powershell-yaml' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            # A typed dump: two readings are the same only when every value has the same type and the same text.
            function Get-Shape {
                param($Value)
                if ($null -eq $Value) { return 'null' }
                $parts = [Collections.Generic.List[string]]::new()
                if ($Value -is [Collections.IDictionary]) {
                    foreach ($key in [Linq.Enumerable]::OrderBy([string[]]@($Value.get_Keys()), [Func[string,string]] { param($k) $k }, [StringComparer]::Ordinal)) { $parts.Add("$key=$(Get-Shape $Value[$key])") }
                    return "$($Value.GetType().Name){$($parts -join ',')}"
                }
                if ($Value -is [Collections.IList]) {
                    foreach ($item in $Value) { $parts.Add((Get-Shape $item)) }
                    return "$($Value.GetType().Name)[$($parts -join ',')]"
                }
                if ($Value -is [datetime]) { return "DateTime:$($Value.ToString('o'))" }
                return "$($Value.GetType().Name):$([Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture))"
            }
            $corpus = @(
                "general:`n  maxItems: 4`n  tracking: false`n  tokenPrice: 0.25`n  currency: EUR`n  hookExcludeCommands: [ls, 'cd']`npumps:`n  - name: git`n    path: C:\x`n    enabled: true`n    priority: 10`n  - name: rust`n    enabled: True",
                "plain: [1, -7, 2147483648, 12345678901234567890, 1.0, 1.5, 1e3, .5, 1e400, abc, 0x1F, .inf, ~, null, NULL, nUlL, '', true, False, yes, 'true', `"12`", NaN, Infinity, -Infinity]",
                "tagged: [!!int 0x7, !!int 0o17, !!int 0x1F, !!int 0X10, !!int 42, !!int 7, !!float .inf, !!float -.Inf, !!float 2.5, !!bool true, !!str 123, !!null x, !!timestamp 2026-10-18T10:00:00Z]",
                "nested: {a: {b: [{c: 1}, [2, [3]]]}, empty: [], none: {}}`nblock: |`n  line 1`n  line 2`nunicode: 'é 漢字'",
                "first: 1`n---`nsecond: 2",
                "", "# comment only", "scalar", "- 1`n- two")
            Import-Module powershell-yaml -RequiredVersion 0.4.12
            foreach ($text in $corpus) {
                (Get-Shape (ConvertFrom-OP2Yaml $text)) | Should -BeExactly (Get-Shape (ConvertFrom-Yaml $text)) -Because $text
            }
            foreach ($text in @('x: !!bool maybe', 'x: !!int abc', 'x: !!float abc', 'x: !!timestamp abc')) {
                { ConvertFrom-Yaml $text } | Should -Throw
                { ConvertFrom-OP2Yaml $text } | Should -Throw
            }
        }
    }
    It 'writes YAML exactly as ConvertTo-Yaml does, with one serializer per session' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            # Scalars YAML could read as another type, multi-line and non-ASCII text, nulls at every level, nested lists
            # and maps: what the quoting emitter, null handling and block styles decide.
            $data = [ordered]@{ Plain = 'hello'; Colon = 'a: b'; Hash = 'x #y'; Lead = ' lead'; Number = '123'; Bool = 'true'; Tilde = '~'; Null = $null
                Multi = "l1`nl2"; Quote = "it's"; Unicode = 'é 漢字'; Path = 'C:\src\F.cs(10,5): error CS0001: x'; Empty = ''; Char = [char]'7'
                Int = 42; Long = [long]::MaxValue; Ratio = 0.25; Flag = $true; Date = [datetime]'2026-10-18T10:00:00Z'
                List = @('a', @(1, 2), [ordered]@{ Key = 'v'; Nothing = $null }, $null); EmptyList = @(); Map = @{ x = @(1) } }
            $document = @((Protect-OP2Value 'record #1: value' 1 (New-OP2Limit 20)), (Compress-OP2Envelope (Protect-OP2Value (New-OP2Completion -Data $data) 1 (New-OP2Limit 20) -Plain)))
            $fast = ConvertTo-OP2Document $document 'yaml'
            Import-Module powershell-yaml -RequiredVersion 0.4.12
            $fast | Should -BeExactly (ConvertTo-Yaml -Data $document -Options DisableAliases)
            [object]::ReferenceEquals((Get-OP2YamlSerializer), (Get-OP2YamlSerializer)) | Should -BeTrue
            ConvertTo-OP2Document $null 'yaml' | Should -BeNullOrEmpty
        }
    }
}
