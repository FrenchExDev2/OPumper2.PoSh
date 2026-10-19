function Invoke-OP2Dispatch {
    # Hands a batch of framed records to the call's callbacks, in order: the batch callback receives the whole batch
    # in one call, the record callback each record, a stream callback each text. The engine assembly frames and counts
    # every record; after a callback failure the remaining records are still counted there, no longer dispatched here.
    param([object[]]$Records, [object]$Context)
    if ($Context.OnBatch) {
        # One call, and one diagnostic check, per batch rather than per record; an empty batch is not handed over.
        if ($Context.Failure -or !$Records.Count) { return }
        try { Invoke-OP2DomainCallback $Context.OnBatch @($Records, $Context.State) }
        catch { $Context.Failure = New-OP2Error 'CallbackFailed' 'Callback' $_.Exception }
        return
    }
    foreach ($record in $Records) {
        if ($Context.Failure) { return }
        $callback = $Context.OnRecord
        $argument = $record
        if (!$callback) {
            $callback = $(if ($record.Stream -eq 'stdout') { $Context.OnStdOut } else { $Context.OnStdErr })
            $argument = $record.Text
        }
        if (!$callback) { continue }
        try {
            Invoke-OP2DomainCallback $callback @($argument,$Context.State)
        } catch { $Context.Failure = New-OP2Error 'CallbackFailed' 'Callback' $_.Exception }
    }
}
