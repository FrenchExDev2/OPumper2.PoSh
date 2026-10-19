# Removes deliveries older than @cutoff, then the invocations no retained delivery links to.
$script:OP2PurgeSql = @'
DELETE FROM delivery_invocations WHERE delivery IN (SELECT id FROM deliveries WHERE timestamp < @cutoff);
DELETE FROM deliveries WHERE timestamp < @cutoff;
DELETE FROM invocations WHERE timestamp < @cutoff AND id NOT IN (SELECT invocation FROM delivery_invocations);
'@

function Get-OP2Timestamp {
    # The clock of the phase durations, in Stopwatch ticks; tests replace it with a predictable one.
    return [Diagnostics.Stopwatch]::GetTimestamp()
}

function Get-OP2Duration {
    # The milliseconds between two timestamps of Get-OP2Timestamp.
    param([long]$Start, [long]$End)
    return ($End - $Start) * 1000.0 / [Diagnostics.Stopwatch]::Frequency
}

function Get-OP2SourceByteCount {
    param([object]$Execution)
    return $Execution.StdoutBytes + $Execution.StderrBytes
}

function Get-OP2ProjectHash {
    # The history stores a hash of the working directory, never the path itself.
    param([string]$Directory)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Directory))))
}

function Get-OP2Fingerprint {
    # Keyed by the database's random salt: equal command lines match within one history, never across histories.
    param([string]$Text, [hashtable]$Configuration)
    $salt = @(Invoke-OP2Sql -Configuration $Configuration -Read -Sql "SELECT value FROM settings WHERE key='salt';")[0].value
    return [Convert]::ToHexString([Security.Cryptography.HMACSHA256]::HashData([Text.Encoding]::UTF8.GetBytes($salt), [Text.Encoding]::UTF8.GetBytes($Text)))
}

function Get-OP2OptionalTokenCount {
    # A part's count is informative: an unavailable counter leaves it unknown without changing the measurement status.
    param([AllowNull()][string]$Text, [hashtable]$Configuration)
    try { return Get-OP2TokenCount $Text $Configuration.Tokenizer } catch { return $null }
}

function Save-OP2Invocation {
    param([object]$Completion, [string]$WorkingDirectory, [string]$Label, [hashtable]$Configuration)
    if (!$Configuration.Tracking) { $Completion.Measurement.Status = 'TrackingDisabled'; return }
    $tokens = $null; $version = 'unavailable'
    # The phases a native call timed (Execution.Timing, kept local), and this count.
    $timing = $(if ($Completion.Execution['Timing']) { $Completion.Execution['Timing'] } else { @{} })
    $counted = Get-OP2Timestamp
    try {
        # The capture holds both complete streams, decoded once, a leading BOM included. Invalid bytes were replaced
        # there: a lossy capture has no exact count.
        if ($Completion.Capture.Lossy) { throw 'A lossy capture has no exact token count.' }
        $tokens = 0L
        foreach ($text in @($Completion.Capture.Stdout, $Completion.Capture.Stderr)) { $tokens += Get-OP2TokenCount $text $Configuration.Tokenizer }
        $version = $script:OP2Tokenizers[$Configuration.Tokenizer].Version
    } catch { $tokens = $null; $Completion.Measurement.Status = 'CounterUnavailable' }
    $tokensMs = Get-OP2Duration $counted (Get-OP2Timestamp)
    $bytes = Get-OP2SourceByteCount $Completion.Execution
    $Completion.Measurement.SourceBytes = $bytes; $Completion.Measurement.SourceTokens = $tokens
    try {
        $writing = Get-OP2Timestamp
        Invoke-OP2Sql -Configuration $Configuration -Sql ('INSERT INTO invocations(id,timestamp,label,project,outcome,bytes,tokens,profile,version,complete,elapsed,session,' +
            'setup_ms,process_ms,callback_ms,backpressure_ms,complete_ms,capture_ms,tokens_ms,records) VALUES(@id,@timestamp,@label,@project,@outcome,@bytes,@tokens,' +
            '@profile,@version,@complete,@elapsed,@session,@setup,@process,@callback,@backpressure,@finish,@capture,@tokensMs,@records)') -Parameters @{
            id = $Completion.Execution.InvocationIds[0]; timestamp = (Get-OP2UtcNow).ToString('O'); label = $Label; project = Get-OP2ProjectHash $WorkingDirectory
            outcome = $Completion.Outcome; bytes = $bytes; tokens = $tokens; profile = $Configuration.Tokenizer; version = $version
            complete = [int]$Completion.Completeness.Source; elapsed = $Completion.Execution.ElapsedMs; session = Get-OP2EnvironmentValue $Configuration.SessionVariable
            setup = $timing['SetupMs']; process = $timing['ProcessMs']; callback = $timing['CallbackMs']; backpressure = $timing['BackpressureMs']
            finish = $timing['CompleteMs']; capture = $timing['CaptureMs']; tokensMs = $tokensMs; records = $Completion.Execution['Records']
        }
        Add-OP2StorageWrite $writing
        if ($null -ne $tokens) { $Completion.Measurement.Status = 'SourceMeasured' }
    } catch { $Completion.Measurement.Status = 'StorageUnavailable' }
}

function Save-OP2Delivery {
    # Origin: Route, Provider and Command (the command line, stored only as a fingerprint). Parts: the delivered Data,
    # records and excerpt texts, and the same delivery in the alternate format when it is measured.
    # Timing: Entered (the entry into pump), RecallMs and FormatMs, measured by the caller; the token counts time
    # themselves here. The total runs from the entry up to this delivery's own write, the one step it cannot include;
    # storage is the writes of its invocations and recall made since the entry. The import of the module is charged
    # once per session, to its first stored delivery.
    param([object]$Completion, [string]$Text, [hashtable]$Configuration, [hashtable]$Origin = @{}, [string]$Format, [hashtable]$Parts = @{},
        [string]$Truncation, [hashtable]$Timing = @{})
    if (!$Configuration.Tracking) { $Completion.Measurement.Status = 'TrackingDisabled'; return }
    $bytes = [Text.Encoding]::UTF8.GetByteCount($Text)
    $tokens = $null; $version = 'unavailable'
    $counted = Get-OP2Timestamp
    try { $tokens = Get-OP2TokenCount $Text $Configuration.Tokenizer; $version = $script:OP2Tokenizers[$Configuration.Tokenizer].Version }
    catch { $Completion.Measurement.Status = 'CounterUnavailable' }
    $partTokens = @{}
    foreach ($name in @('Data', 'Records', 'Excerpt', 'Alternate')) { $partTokens[$name] = Get-OP2OptionalTokenCount $Parts[$name] $Configuration }
    $tokensMs = Get-OP2Duration $counted (Get-OP2Timestamp)
    try {
        $id = [guid]::NewGuid().ToString('N')
        $fingerprint = $(if ($Origin['Command']) { Get-OP2Fingerprint $Origin['Command'] $Configuration } else { $null })
        $entered = $Timing['Entered']
        $parameters = @{ id = $id; timestamp = (Get-OP2UtcNow).ToString('O'); bytes = $bytes; tokens = $tokens; profile = $Configuration.Tokenizer; version = $version
            route = $Origin['Route']; provider = $Origin['Provider']; format = $Format; outcome = $Completion.Outcome
            truncation = $(if ($Truncation) { $Truncation } else { $null }); session = Get-OP2EnvironmentValue $Configuration.SessionVariable
            fingerprint = $fingerprint; data = $partTokens.Data; records = $partTokens.Records; excerpt = $partTokens.Excerpt
            alternateFormat = $Parts['AlternateFormat']; alternateBytes = $null; alternateTokens = $null
            recall = $Timing['RecallMs']; formatting = $Timing['FormatMs']; tokensMs = $tokensMs
            storage = $(if ($null -ne $entered) { Get-OP2StorageDuration $entered } else { $null })
            import = $(if ($script:OP2ImportPending) { $script:OP2ImportMs } else { $null }) }
        # Last: the total covers the counts and the fingerprint above.
        $parameters.total = $(if ($null -ne $entered) { Get-OP2Duration $entered (Get-OP2Timestamp) } else { $null })
        if ($Parts['AlternateFormat']) {
            $parameters.alternateBytes = [Text.Encoding]::UTF8.GetByteCount($Parts['Alternate'])
            $parameters.alternateTokens = $partTokens.Alternate
        }
        $sql = [Text.StringBuilder]::new('BEGIN; INSERT INTO deliveries(id,timestamp,bytes,tokens,profile,version,route,provider,format,outcome,truncation,session,fingerprint,' +
            'data_tokens,record_tokens,excerpt_tokens,alternate_format,alternate_bytes,alternate_tokens,total_ms,recall_ms,format_ms,tokens_ms,storage_ms,import_ms) VALUES(@id,' +
            '@timestamp,@bytes,@tokens,@profile,@version,@route,@provider,@format,@outcome,@truncation,@session,@fingerprint,@data,@records,@excerpt,' +
            '@alternateFormat,@alternateBytes,@alternateTokens,@total,@recall,@formatting,@tokensMs,@storage,@import);')
        $index = 0
        foreach ($invocation in @($Completion.Execution.InvocationIds | Select-Object -Unique)) {
            $parameters["call$index"] = $invocation
            [void]$sql.Append("INSERT INTO delivery_invocations SELECT @id,id FROM invocations WHERE id=@call$index;")
            $index++
        }
        # Retention runs with each delivery, in the same transaction.
        if ($Configuration.RetentionDays -gt 0) {
            $parameters.cutoff = (Get-OP2UtcNow).AddDays(-$Configuration.RetentionDays).ToString('O')
            [void]$sql.Append($script:OP2PurgeSql)
        }
        [void]$sql.Append('COMMIT;')
        Invoke-OP2Sql -Configuration $Configuration -Sql $sql.ToString() -Parameters $parameters
        $script:OP2ImportPending = $false
        $Completion.Measurement.OutputBytes = $bytes; $Completion.Measurement.OutputTokens = $tokens
        $Completion.Measurement.Status = $(if ($null -ne $tokens) { 'Delivered' } else { 'DeliveredWithoutTokens' })
    } catch { $Completion.Measurement.Status = 'DeliveryUnavailable' }
}
