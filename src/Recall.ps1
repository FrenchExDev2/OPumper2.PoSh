# Removes recalls older than @cutoff or beyond the @keep most recent, with their reads.
$script:OP2RecallPurgeSql = @'
DELETE FROM recall_reads WHERE recall IN (SELECT id FROM recalls WHERE timestamp < @cutoff OR id NOT IN (SELECT id FROM recalls ORDER BY timestamp DESC LIMIT @keep));
DELETE FROM recalls WHERE timestamp < @cutoff OR id NOT IN (SELECT id FROM recalls ORDER BY timestamp DESC LIMIT @keep);
'@

function ConvertTo-OP2RecallBlob {
    # Gzip of the UTF-8 text; no text stays null.
    param([object]$Text)
    if ($null -eq $Text) { return $null }
    $buffer = [IO.MemoryStream]::new()
    $zip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionLevel]::Optimal)
    try { $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text); $zip.Write($bytes, 0, $bytes.Length) } finally { $zip.Dispose() }
    return ,$buffer.ToArray()
}

function ConvertFrom-OP2RecallBlob {
    param([object]$Blob)
    if ($null -eq $Blob) { return $null }
    $zip = [IO.Compression.GZipStream]::new([IO.MemoryStream]::new([byte[]]$Blob), [IO.Compression.CompressionMode]::Decompress)
    $reader = [IO.StreamReader]::new($zip, [Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Test-OP2RecallWanted {
    # Only a delivered native output is kept: every one (on), or unsuccessful ones (failures).
    param([object]$Completion, [hashtable]$Configuration)
    if (!$Configuration.Tracking -or $Configuration.Recall -eq 'off') { return $false }
    if (!$Completion.PSObject.Properties['Capture'] -or $null -eq $Completion.Capture -or !@($Completion.Execution.InvocationIds).Count) { return $false }
    return ($Configuration.Recall -eq 'on' -or $Completion.Outcome -ne 'Success')
}

function Save-OP2Recall {
    # Keeps the complete output of a delivered call, masked by the obfuscation pipe unless recallMask is off, cut to
    # its last recallMaxEntryBytes per stream. Returns the recall id, or nothing.
    param([object]$Completion, [hashtable]$Configuration, [hashtable]$Origin = @{})
    if (!(Test-OP2RecallWanted $Completion $Configuration)) { return $null }
    try {
        $invocation = @($Completion.Execution.InvocationIds)[0]
        $complete = [bool]$Completion.Capture.Complete
        $streams = @{}
        foreach ($name in @('Stdout','Stderr')) {
            $text = $Completion.Capture[$name]
            if ($null -ne $text -and $Configuration.RecallMask) { $text = [string](Invoke-OP2Obfuscation $text @{ Key = $name; Path = "Recall.$name"; Depth = 0 } $null) }
            if ($null -ne $text) {
                $bytes = [Text.Encoding]::UTF8.GetBytes($text)
                if ($bytes.Length -gt $Configuration.RecallMaxEntryBytes) {
                    $text = [Text.Encoding]::UTF8.GetString($bytes, $bytes.Length - $Configuration.RecallMaxEntryBytes, $Configuration.RecallMaxEntryBytes)
                    $complete = $false
                }
            }
            $streams[$name] = $text
        }
        $directory = $(if ($Origin['WorkingDirectory']) { $Origin['WorkingDirectory'] } else { (Get-Location).Path })
        $parameters = @{ id = $invocation.Substring(0, 12); timestamp = (Get-OP2UtcNow).ToString('O'); invocation = $invocation
            label = $Origin['Label']; route = $Origin['Route']; project = Get-OP2ProjectHash $directory; outcome = $Completion.Outcome
            exitCode = $Completion.Execution['ExitCode']; stdout = ConvertTo-OP2RecallBlob $streams.Stdout; stderr = ConvertTo-OP2RecallBlob $streams.Stderr
            stdoutBytes = [long]$Completion.Execution['StdoutBytes']; stderrBytes = [long]$Completion.Execution['StderrBytes']
            complete = [int]$complete; masked = [int][bool]$Configuration.RecallMask
            cutoff = $(if ($Configuration.RecallRetentionDays) { (Get-OP2UtcNow).AddDays(-$Configuration.RecallRetentionDays).ToString('O') } else { '' })
            keep = $(if ($Configuration.RecallMaxEntries) { $Configuration.RecallMaxEntries } else { [int]::MaxValue }) }
        $writing = Get-OP2Timestamp
        Invoke-OP2Sql -Configuration $Configuration -Parameters $parameters -Sql ('BEGIN; INSERT OR REPLACE INTO recalls(id,timestamp,invocation,label,route,project,outcome,exit_code,stdout,stderr,stdout_bytes,stderr_bytes,complete,masked) ' +
            'VALUES(@id,@timestamp,@invocation,@label,@route,@project,@outcome,@exitCode,@stdout,@stderr,@stdoutBytes,@stderrBytes,@complete,@masked);' + $script:OP2RecallPurgeSql + 'COMMIT;')
        Add-OP2StorageWrite $writing
        return $parameters.id
    } catch { return $null }
}

function Read-OP2Recall {
    param([string]$Id, [hashtable]$Configuration)
    $rows = @(Invoke-OP2Sql -Configuration $Configuration -Read -Sql 'SELECT * FROM recalls WHERE id=@id;' -Parameters @{ id = $Id })
    if (!$rows.Count) { throw "Unknown recall: $Id." }
    $row = $rows[0]
    [pscustomobject]@{ Id = $row.id; Timestamp = $row.timestamp; Invocation = $row.invocation; Label = $row.label; Route = $row.route
        Outcome = $row.outcome; ExitCode = $row.exit_code; Stdout = ConvertFrom-OP2RecallBlob $row.stdout; Stderr = ConvertFrom-OP2RecallBlob $row.stderr
        Complete = [bool]$row.complete; Masked = [bool]$row.masked }
}

function Invoke-OP2Replay {
    # Frames a recalled output through a contract's callbacks as the native runner frames live streams, line by line:
    # all of stdout, then all of stderr. The completion reports the recalled exit code; replaying never runs the command.
    param([object]$Recall, [hashtable]$Call)
    $context = New-OP2CallbackContext $Call
    foreach ($name in @('stdout','stderr')) {
        $text = $(if ($name -eq 'stdout') { $Recall.Stdout } else { $Recall.Stderr })
        if ($null -ne $text) { Invoke-OP2Dispatch ([FrenchExDev.OPumper2.Engine.Framer]::Frame($text, $name, [char]"`n", $Call.MaxRecordCharacters, $context.Counter)) $context }
    }
    $framing = Get-OP2FramingError $context
    $outcome = $(if ($framing) { 'Failed' } else { 'Success' })
    $execution = New-OP2Execution @{ ExitCode = $Recall.ExitCode; FinalizerError = $null; Records = $context.Counter.Sequence; Recall = $Recall.Id }
    return Complete-OP2Call $Call $context $execution $outcome $framing $Recall.Complete
}

function New-OP2ReplayCall {
    # The call shape replays share with native calls.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates an in-memory call description; nothing runs.')]
    param([scriptblock]$OnRecord, [scriptblock]$OnStdOut, [scriptblock]$OnStdErr, [object]$State, [scriptblock]$Complete, [int]$MaxRecordCharacters = 65536, [scriptblock]$OnBatch)
    @{ OnRecord = $OnRecord; OnBatch = $OnBatch; OnStdOut = $OnStdOut; OnStdErr = $OnStdErr; State = $State; Complete = $Complete; MaxRecordCharacters = $MaxRecordCharacters }
}

function Send-OP2RecallRead {
    # Delivers what was read from the recall store and records the read; reads are not deliveries of new output.
    param([object]$Result, [string]$Recall, [string]$Mode, [hashtable]$Bound, [hashtable]$Configuration)
    $options = Resolve-OP2CallOption $Bound -Configuration $Configuration
    $format = $options.Format
    if ($format -eq 'object') { return $Result }
    $delivery = Format-OP2Delivery @($Result) $format $options.MaxItems $options.MaxOutputBytes $options.ExcerptLines $Configuration
    if ($Configuration.Tracking) {
        try {
            Invoke-OP2Sql -Configuration $Configuration -Sql 'INSERT INTO recall_reads VALUES(@id,@recall,@timestamp,@mode,@bytes,@tokens);' -Parameters @{
                id = [guid]::NewGuid().ToString('N'); recall = $Recall; timestamp = (Get-OP2UtcNow).ToString('O'); mode = $Mode
                bytes = [Text.Encoding]::UTF8.GetByteCount($delivery.Text); tokens = Get-OP2OptionalTokenCount $delivery.Text $Configuration }
        } catch { $Result.Measurement.Status = 'DeliveryUnavailable' }
    }
    return $delivery.Text
}

function Get-OPumper2Recall {
    # Reads a recalled output instead of running its command again: numbered lines from From, those matching Grep,
    # of one stream or both; or the list of stored recalls. Lines and the delivery are bounded like any delivery.
    [CmdletBinding(DefaultParameterSetName='Read')]
    param([Parameter(Mandatory, Position=0, ParameterSetName='Read')][string]$Id,
        [Parameter(ParameterSetName='Read')][ValidateSet('all','stdout','stderr')][string]$Stream = 'all',
        [Parameter(ParameterSetName='Read')][string]$Grep,
        [Parameter(ParameterSetName='Read')][ValidateRange(1,[int]::MaxValue)][int]$From = 1,
        [Parameter(ParameterSetName='Read')][ValidateRange(1,[int]::MaxValue)][int]$Lines,
        [Parameter(Mandatory, ParameterSetName='List')][switch]$List,
        [string]$DatabasePath, [switch]$AsObject, [switch]$AsJson, [switch]$AsYaml,
        [ValidateRange(0,[int]::MaxValue)][int]$MaxItems, [ValidateRange(256,[int]::MaxValue)][int]$MaxOutputBytes)
    $configuration = Get-OP2Configuration
    if ($DatabasePath) { $configuration.DatabasePath = @(Resolve-OP2DatabasePath $DatabasePath $configuration)[0] }
    if ($List) {
        $rows = @(Invoke-OP2Sql -Configuration $configuration -Read -Sql 'SELECT id AS Id, timestamp AS Timestamp, COALESCE(route,label) AS Command, outcome AS Outcome, stdout_bytes + stderr_bytes AS Bytes, complete AS Complete FROM recalls ORDER BY timestamp DESC;')
        $result = New-OPumper2Result -Data ([ordered]@{ Recalls = $rows }) -Projection { param($data, $settings) Limit-OPumper2Projection ([ordered]@{ Recalls = $data.Recalls }) @('Recalls') $settings }
        $options = Resolve-OP2CallOption $PSBoundParameters -Configuration $configuration
        $format = $options.Format
        if ($format -eq 'object') { return $result }
        return (Format-OP2Delivery @($result) $format $options.MaxItems $options.MaxOutputBytes 0 $configuration).Text
    }
    $recall = Read-OP2Recall $Id $configuration
    $state = @{ Stream = $Stream; Regex = $(if ($Grep) { [regex]::new($Grep) } else { $null }); From = $From; Lines = 0L; Matched = 0L; Text = [Collections.Generic.List[string]]::new()
        Limit = $(if ($Lines) { $Lines } else { [int]::MaxValue }) }
    $collect = {
        param($record, $s)
        if ($s.Stream -ne 'all' -and $record.Stream -ne $s.Stream) { return }
        $s.Lines++
        if ($s.Lines -lt $s.From -or ($s.Regex -and !$s.Regex.IsMatch($record.Text))) { return }
        $s.Matched++
        if ($s.Text.Count -lt $s.Limit) { $s.Text.Add("$($s.Lines): $($record.Text)") }
    }
    $finish = { param($s) [ordered]@{ Lines = $s.Lines; Matched = $s.Matched; Text = $s.Text } }
    $replayed = Invoke-OP2Replay $recall (New-OP2ReplayCall -OnRecord $collect -State $state -Complete $finish)
    $data = [ordered]@{ Recall = $recall.Id; Command = $(if ($recall.Route) { $recall.Route } else { $recall.Label }); Outcome = $recall.Outcome
        ExitCode = $recall.ExitCode; Complete = $recall.Complete; Lines = $replayed.Data.Lines; Matched = $replayed.Data.Matched; Text = $replayed.Data.Text }
    $result = New-OPumper2Result -Completion $replayed -Data $data -Projection { param($data, $settings) Limit-OPumper2Projection $data @('Text') $settings }
    return Send-OP2RecallRead $result $recall.Id 'lines' $PSBoundParameters $configuration
}

function Invoke-OPumper2Recall {
    # Applies a new contract to a recalled output, without running its command again.
    [CmdletBinding(DefaultParameterSetName='Record')]
    param([Parameter(Mandatory, Position=0)][string]$Id,
        [Parameter(Mandatory, ParameterSetName='Record')][scriptblock]$OnRecord,
        [Parameter(Mandatory, ParameterSetName='Batch')][scriptblock]$OnBatch,
        [Parameter(ParameterSetName='Streams')][scriptblock]$OnStdOut, [Parameter(ParameterSetName='Streams')][scriptblock]$OnStdErr,
        [object]$State, [scriptblock]$Complete, [string]$DatabasePath,
        [switch]$AsObject, [switch]$AsJson, [switch]$AsYaml,
        [ValidateRange(0,[int]::MaxValue)][int]$MaxItems, [ValidateRange(256,[int]::MaxValue)][int]$MaxOutputBytes, [ValidateRange(0,[int]::MaxValue)][int]$ExcerptLines)
    $configuration = Get-OP2Configuration
    if ($DatabasePath) { $configuration.DatabasePath = @(Resolve-OP2DatabasePath $DatabasePath $configuration)[0] }
    $recall = Read-OP2Recall $Id $configuration
    $replayed = Invoke-OP2Replay $recall (New-OP2ReplayCall -OnRecord $OnRecord -OnBatch $OnBatch -OnStdOut $OnStdOut -OnStdErr $OnStdErr -State $State -Complete $Complete)
    return Send-OP2RecallRead $replayed $recall.Id 'contract' $PSBoundParameters $configuration
}
