# One row per delivery: its context, its delivered volume and composition, and the summed volume of its source invocations.
$script:OP2GainDeliverySql = @'
SELECT d.id AS Id, d.timestamp AS Timestamp, d.route AS Route, d.provider AS Provider, d.format AS Format, d.outcome AS Outcome,
d.truncation AS Truncation, d.session AS Session, d.fingerprint AS Fingerprint, MIN(i.label) AS Label, MIN(i.project) AS Project,
d.bytes AS OutputBytes, d.tokens AS OutputTokens, d.data_tokens AS DataTokens, d.record_tokens AS RecordTokens, d.excerpt_tokens AS ExcerptTokens,
d.alternate_format AS AlternateFormat, d.alternate_bytes AS AlternateBytes, d.alternate_tokens AS AlternateTokens,
SUM(i.bytes) AS SourceBytes, SUM(i.tokens) AS SourceTokens, COUNT(*) AS Calls, MIN(i.complete) AS Complete,
SUM(i.tokens IS NULL) AS UnknownTokens, SUM(i.elapsed) AS ElapsedMs,
(SELECT MAX(rc.id) FROM recalls rc JOIN delivery_invocations dx ON dx.invocation=rc.invocation WHERE dx.delivery=d.id) AS RecallId,
(SELECT COUNT(*) FROM recall_reads rr JOIN recalls rc ON rc.id=rr.recall JOIN delivery_invocations dx ON dx.invocation=rc.invocation WHERE dx.delivery=d.id) AS RecallReads,
@database AS Database, 0 AS Rerun
FROM deliveries d JOIN delivery_invocations x ON x.delivery=d.id JOIN invocations i ON i.id=x.invocation
WHERE i.profile=d.profile AND i.version=d.version AND d.profile=@profile AND d.version=@version
AND (@since IS NULL OR d.timestamp >= @since) AND (@project IS NULL OR i.project=@project) AND (@session IS NULL OR d.session=@session)
GROUP BY d.id ORDER BY d.timestamp;
'@

# Invocations no delivery links to: local objects (-AsObject) whose output never entered a delivered text.
$script:OP2GainLocalSql = @'
SELECT COUNT(*) AS Invocations, COALESCE(SUM(i.bytes),0) AS SourceBytes, COALESCE(SUM(i.tokens),0) AS SourceTokens FROM invocations i
WHERE i.profile=@profile AND i.version=@version AND NOT EXISTS (SELECT 1 FROM delivery_invocations x WHERE x.invocation=i.id)
AND (@since IS NULL OR i.timestamp >= @since) AND (@project IS NULL OR i.project=@project) AND (@session IS NULL OR i.session=@session);
'@

function Read-OP2GainHistory {
    # Rows of the given databases in chronological order, each tagged with its database, and the local volume. The query
    # itself selects the database and the rerun flag, which per-row Add-Member calls would cost seconds.
    param([hashtable]$Configuration, [string[]]$Database, [hashtable]$Filter)
    $rows = [Collections.Generic.List[object]]::new()
    $local = [ordered]@{ Invocations = 0L; SourceBytes = 0L; SourceTokens = 0L }
    foreach ($path in $Database) {
        $settings = $Configuration.Clone()
        $settings.DatabasePath = $path
        $tagged = $Filter.Clone()
        $tagged.database = $path
        foreach ($row in @(Invoke-OP2Sql -Configuration $settings -Read -Sql $script:OP2GainDeliverySql -Parameters $tagged)) { $rows.Add($row) }
        $count = @(Invoke-OP2Sql -Configuration $settings -Read -Sql $script:OP2GainLocalSql -Parameters $Filter)[0]
        foreach ($name in @($local.Keys)) { $local[$name] += $count.$name }
    }
    [pscustomobject]@{ Rows = @($rows | Sort-Object Timestamp); Local = $local }
}
