BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    function New-CompletionFixture {param([object]$Data) InModuleScope FrenchExDev.OPumper2.PoSh -Parameters @{Data=$Data} {New-OP2Completion -Data $Data -Execution @{ExitCode=0;InvocationIds=@();ElapsedMs=1}}}
}

Describe 'Obfuscation pipe' {
    AfterEach { InModuleScope FrenchExDev.OPumper2.PoSh { Initialize-OP2Obfuscator } }

    It 'exposes the ordered built-in middlewares' {
        $listed=@(Get-OPumper2Obfuscator)
        ($listed.Id -join ',') | Should -Be 'builtin.secret-keys,builtin.secret-assignments,builtin.bearer,builtin.url-credentials'
        ($listed.Position -join ',') | Should -Be '0,1,2,3'
        ($listed.Kind -join ',') | Should -Be 'Key,Text,Text,Text'
        @($listed | Where-Object {!$_.BuiltIn}).Count | Should -Be 0
    }
    It 'masks secret keys, assignments, bearer tokens and URL credentials in delivered text' {
        InModuleScope FrenchExDev.OPumper2.PoSh {
            $data=[pscustomobject]@{
                Password=@('first','second'); Environment=@{PATH='fixture'}; Items=@('password','plain')
                Header='Authorization: Basic dXNlcjpwYXNz'; Assignment='api_key=abc;next'; Curl='-H Bearer abc.def+/=='
                Url='https://alice:s3cret@example.com/r.git'; Pat='clone https://ghp_fixture@github.com/x and done'; Plain='hello world'
            }
            $parsed=ConvertTo-OPumper2Output @((New-OP2Completion -Data $data)) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate
            $masked=$parsed[0].Data
            $masked.Password | Should -Be '[REDACTED]'
            $masked.Environment | Should -Be '[REDACTED]'
            ($masked.Items -join ',') | Should -Be 'password,plain'
            $masked.Header | Should -Be 'Authorization=[REDACTED]'
            $masked.Assignment | Should -Be 'api_key=[REDACTED];next'
            $masked.Curl | Should -Be '-H Bearer [REDACTED]'
            $masked.Url | Should -Be 'https://[REDACTED]@example.com/r.git'
            $masked.Pat | Should -Be 'clone https://[REDACTED]@github.com/x and done'
            $masked.Plain | Should -Be 'hello world'
            $parsed[0].ContainsKey('Truncation') | Should -BeFalse
            Protect-OP2Value 'token' | Should -Be 'token'
        }
    }
    It 'registers case-insensitive key and text patterns with replacements' {
        $key=Register-OPumper2Obfuscator -Id fixture.key -KeyPattern '^host$'
        $text=Register-OPumper2Obfuscator -Id fixture.text -TextPattern '(user)=\w+' -Replacement '$1=***'
        $key.Kind | Should -Be 'Key'; $key.Position | Should -Be 4; $key.BuiltIn | Should -BeFalse
        $text.Kind | Should -Be 'Text'; $text.Position | Should -Be 5
        $record=[pscustomobject]@{HOST='internal.example';Note='USER=alice and user=bob';Port=22}
        $parsed=ConvertTo-OPumper2Output @($record,(New-CompletionFixture)) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate
        $parsed[0].HOST | Should -Be '[REDACTED]'
        $parsed[0].Note | Should -Be 'USER=*** and user=***'
        $parsed[0].Port | Should -Be 22
    }
    It 'orders middlewares by registration and Before' {
        Register-OPumper2Obfuscator -Id fixture.first -TextPattern 'x' -Replacement 'y' | Out-Null
        Register-OPumper2Obfuscator -Id fixture.second -TextPattern 'y' -Replacement 'z' | Out-Null
        (ConvertTo-OPumper2Output @('x',(New-CompletionFixture)) -Format json | ConvertFrom-Json -NoEnumerate)[0] | Should -Be 'z'
        Unregister-OPumper2Obfuscator fixture.second | Should -BeTrue
        $inserted=Register-OPumper2Obfuscator -Id fixture.second -TextPattern 'y' -Replacement 'z' -Before FIXTURE.FIRST
        $inserted.Position | Should -Be 4
        ((Get-OPumper2Obfuscator).Id -join ',') | Should -Be 'builtin.secret-keys,builtin.secret-assignments,builtin.bearer,builtin.url-credentials,fixture.second,fixture.first'
        (ConvertTo-OPumper2Output @('x',(New-CompletionFixture)) -Format json | ConvertFrom-Json -NoEnumerate)[0] | Should -Be 'y'
        (Register-OPumper2Obfuscator -Id fixture.front -Middleware {param($v,$c)} -Before builtin.secret-keys).Position | Should -Be 0
        (Get-OPumper2Obfuscator)[0].Kind | Should -Be 'Script'
    }
    It 'rejects invalid, duplicate, reserved and misplaced registrations' {
        {Register-OPumper2Obfuscator -Id ' ' -TextPattern 'x'} | Should -Throw '*builtin prefix*'
        {Register-OPumper2Obfuscator -Id builtin.custom -TextPattern 'x'} | Should -Throw '*builtin prefix*'
        Register-OPumper2Obfuscator -Id fixture.once -TextPattern 'x' | Out-Null
        {Register-OPumper2Obfuscator -Id FIXTURE.ONCE -TextPattern 'x'} | Should -Throw '*Duplicate*'
        {Register-OPumper2Obfuscator -Id fixture.orphan -TextPattern 'x' -Before fixture.missing} | Should -Throw '*Unknown*'
        {Register-OPumper2Obfuscator -Id fixture.invalid -TextPattern '('} | Should -Throw
        {Unregister-OPumper2Obfuscator builtin.bearer} | Should -Throw '*cannot be removed*'
        Unregister-OPumper2Obfuscator fixture.missing | Should -BeFalse
        Unregister-OPumper2Obfuscator fixture.once | Should -BeTrue
        @(Get-OPumper2Obfuscator).Count | Should -Be 4
    }
    It 'passes key, path and depth for records, dictionaries, arrays and completion data' {
        $seen=[Collections.Generic.List[object]]::new()
        Register-OPumper2Obfuscator -Id fixture.trace -Middleware {param($value,$context) $seen.Add([pscustomobject]@{Key=$context.Key;Path=$context.Path;Depth=$context.Depth})}.GetNewClosure() | Out-Null
        $record=[pscustomobject]@{Map=@{Inner='v'};List=@('a','b')}
        $null=ConvertTo-OPumper2Output @($record,(New-CompletionFixture @{Host='h'})) -Format json
        $trace=@($seen | ForEach-Object {'{0}|{1}|{2}' -f $_.Key,$_.Path,$_.Depth})
        $trace | Should -Contain '|[0]|1'
        $trace | Should -Contain 'Map|[0].Map|2'
        $trace | Should -Contain 'Inner|[0].Map.Inner|3'
        $trace | Should -Contain 'List|[0].List|2'
        $trace | Should -Contain '|[0].List[1]|3'
        $trace | Should -Contain 'Data|Data|2'
        $trace | Should -Contain 'Host|Data.Host|3'
        @($seen | Where-Object {$_.Path -in @('Kind','Outcome','Truncation','Truncation.Reasons')}).Count | Should -Be 0
        # Failure diagnostics: excerpt lines and error messages are masked; other metadata is not.
        $seen.Clear()
        $failed=InModuleScope FrenchExDev.OPumper2.PoSh {
            $completion=New-OP2Completion -Outcome Failed -ErrorInfo (New-OP2Error 'ExecutionFailed' 'Execution' ([Exception]::new('detail')))
            $completion.Capture=@{Stdout=$null;Stderr="first`nsecond";Complete=$true;Lossy=$false}
            $completion
        }
        $null=ConvertTo-OPumper2Output @($failed) -Format json
        $trace=@($seen | ForEach-Object {'{0}|{1}|{2}' -f $_.Key,$_.Path,$_.Depth})
        $trace | Should -Contain 'Stderr|Excerpt.Stderr[0]|0'
        $trace | Should -Contain 'Stderr|Excerpt.Stderr[1]|0'
        $trace | Should -Contain 'Message|Error.Message|3'
        @($seen | Where-Object {$_.Path -in @('Error.Code','Error.ExceptionType')}).Count | Should -Be 0
    }
    It 'keeps, replaces or fails closed according to middleware output' {
        $calls=@{After=0}
        Register-OPumper2Obfuscator -Id fixture.rules -Middleware {
            param($value,$context)
            switch ($context.Key) {
                'Nulled' {$null}
                'Listed' {,@('x','y')}
                'Twice' {'a';'b'}
                'Thrown' {throw 'fixture'}
                'Errored' {Write-Error 'fixture'}
                'Informed' {Write-Information 'fixture'}
            }
        } | Out-Null
        Register-OPumper2Obfuscator -Id fixture.after -Middleware {param($value,$context) if($context.Key -eq 'Thrown'){$calls.After++}}.GetNewClosure() | Out-Null
        $record=[pscustomobject]@{Kept='same';Nulled='gone';Listed='scalar';Twice='v';Thrown='v';Errored='v';Informed='v'}
        $parsed=ConvertTo-OPumper2Output @($record,(New-CompletionFixture)) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate
        $parsed[0].Kept | Should -Be 'same'
        $parsed[0].Nulled | Should -BeNullOrEmpty
        ($parsed[0].Listed -join ',') | Should -Be 'x,y'
        foreach($key in @('Twice','Thrown','Errored','Informed')) {$parsed[0][$key] | Should -Be '[OBFUSCATION FAILED]'}
        $calls.After | Should -Be 0
        $parsed[-1].Truncation.Applied | Should -BeTrue
        ($parsed[-1].Truncation.Reasons -join ',') | Should -Be 'ObfuscationFailed'
        $parsed[-1].Truncation.ContainsKey('OmittedRecords') | Should -BeFalse
        (InModuleScope FrenchExDev.OPumper2.PoSh {Protect-OP2Value ([pscustomobject]@{Thrown='v'})}).Thrown | Should -Be '[OBFUSCATION FAILED]'
    }
    It 'leaves engine metadata and object output untouched' {
        Register-OPumper2Obfuscator -Id fixture.all -KeyPattern '.*' | Out-Null
        $completion=New-CompletionFixture @{Host='internal'}
        $parsed=ConvertTo-OPumper2Output @([pscustomobject]@{Name='record'},$completion) -Format json | ConvertFrom-Json -AsHashtable -NoEnumerate
        $parsed[0].Name | Should -Be '[REDACTED]'
        $parsed[1].Kind | Should -Be 'Completion'
        $parsed[1].Outcome | Should -Be 'Success'
        $parsed[1].Data | Should -Be '[REDACTED]'
        $parsed[1].Execution.ExitCode | Should -Be 0
        $value=[pscustomobject]@{Password='kept-local'}
        $objects=@(ConvertTo-OPumper2Output @($value,$completion) -Format object)
        [object]::ReferenceEquals($objects[0],$value) | Should -BeTrue
        $objects[0].Password | Should -Be 'kept-local'
    }
}
