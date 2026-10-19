function Open-OP2Capture {
    param([string]$Path)
    [IO.File]::OpenWrite($Path)
}

function New-OP2Spool {
    # A temporary capture file for one stream. A spool that cannot be opened leaves its capture incomplete; it never
    # fails the call. Every created file is recorded for deletion.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates a private temporary file the call deletes.')]
    param([Collections.Generic.List[string]]$Paths)
    $spool = $null; $path = $null
    try { $path = [IO.Path]::GetTempFileName(); $Paths.Add($path); $spool = Open-OP2Capture $path }
    catch { $spool = $null }
    [pscustomobject]@{ Spool = $spool; Path = $path }
}

function Read-OP2Capture {
    param([object[]]$Streams, [string]$EncodingName, [bool]$SourceComplete)
    # The complete decoded streams of the local object. Strict decoding first; invalid bytes are replaced and marked lossy.
    $capture = @{ Stdout = $null; Stderr = $null; Complete = $SourceComplete; Lossy = $false }
    foreach ($stream in $Streams) {
        if (!$stream.CaptureComplete) { $capture.Complete = $false }
        if (!$stream.Spooled) { continue }
        $key = $(if ($stream.Name -eq 'stdout') { 'Stdout' } else { 'Stderr' })
        try {
            $bytes = [IO.File]::ReadAllBytes($stream.Path)
            try { $capture[$key] = [Text.Encoding]::GetEncoding($EncodingName,[Text.EncoderExceptionFallback]::new(),[Text.DecoderExceptionFallback]::new()).GetString($bytes) }
            catch [Text.DecoderFallbackException] { $capture[$key] = [Text.Encoding]::GetEncoding($EncodingName).GetString($bytes); $capture.Lossy = $true }
        } catch { $capture.Complete = $false }
    }
    return $capture
}

function Get-OP2InputEncoding {
    # A call encoding for standard input: UTF-8 without a byte order mark, which a child would read as text.
    param([string]$Name)
    $encoding = [Text.Encoding]::GetEncoding($Name)
    if ($encoding.CodePage -eq 65001) { return [Text.UTF8Encoding]::new($false) }
    return $encoding
}

function New-OP2StartInfo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates an in-memory process configuration; it does not start a process.')]
    param([hashtable]$Call)
    $info = [Diagnostics.ProcessStartInfo]::new($Call.Command)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.RedirectStandardInput = ($null -ne $Call.InputText)
    # The child reads its input in the encoding its output is decoded with, never the console code page.
    if ($info.RedirectStandardInput) { $info.StandardInputEncoding = Get-OP2InputEncoding $Call.Encoding }
    $info.WorkingDirectory = [IO.Path]::GetFullPath($Call.WorkingDirectory)
    foreach ($argument in $Call.ArgumentList) { $info.ArgumentList.Add($argument) }
    foreach ($key in $Call.Environment.Keys) {
        if ($null -eq $Call.Environment[$key]) { [void]$info.Environment.Remove($key) }
        else { $info.Environment[$key] = [string]$Call.Environment[$key] }
    }
    return $info
}

function Invoke-OP2Termination {
    # Kills the child's tree at the deadline; five seconds later, abandons the streams an orphaned grandchild may hold.
    param([object]$Run, [double]$ElapsedSeconds, [double]$TimeoutSeconds)
    $Run.Kill()
    if ($ElapsedSeconds -ge $TimeoutSeconds+5) { $Run.Abandon() }
}
