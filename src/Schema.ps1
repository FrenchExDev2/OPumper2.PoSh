# Ordered migrations: schema version n is reached by applying the first n entries. A new version appends one entry.
$script:OP2Migrations = @(
    # 1: invocations, deliveries and their links.
    @'
CREATE TABLE IF NOT EXISTS invocations(id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, label TEXT NOT NULL, project TEXT NOT NULL, outcome TEXT NOT NULL, bytes INTEGER NOT NULL, tokens INTEGER, profile TEXT NOT NULL, version TEXT NOT NULL, complete INTEGER NOT NULL, elapsed REAL NOT NULL);
CREATE TABLE IF NOT EXISTS deliveries(id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, bytes INTEGER NOT NULL, tokens INTEGER, profile TEXT NOT NULL, version TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS delivery_invocations(delivery TEXT NOT NULL REFERENCES deliveries(id), invocation TEXT NOT NULL REFERENCES invocations(id), PRIMARY KEY(delivery,invocation));
'@,
    # 2: the route of a routed delivery.
    'ALTER TABLE deliveries ADD COLUMN route TEXT;',
    # 3: delivery context and composition, sessions, the fingerprint salt and history indexes.
    @'
ALTER TABLE deliveries ADD COLUMN provider TEXT;
ALTER TABLE deliveries ADD COLUMN format TEXT;
ALTER TABLE deliveries ADD COLUMN outcome TEXT;
ALTER TABLE deliveries ADD COLUMN truncation TEXT;
ALTER TABLE deliveries ADD COLUMN session TEXT;
ALTER TABLE deliveries ADD COLUMN fingerprint TEXT;
ALTER TABLE deliveries ADD COLUMN data_tokens INTEGER;
ALTER TABLE deliveries ADD COLUMN record_tokens INTEGER;
ALTER TABLE deliveries ADD COLUMN excerpt_tokens INTEGER;
ALTER TABLE deliveries ADD COLUMN alternate_format TEXT;
ALTER TABLE deliveries ADD COLUMN alternate_bytes INTEGER;
ALTER TABLE deliveries ADD COLUMN alternate_tokens INTEGER;
ALTER TABLE invocations ADD COLUMN session TEXT;
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT OR IGNORE INTO settings VALUES('salt', lower(hex(randomblob(32))));
CREATE INDEX IF NOT EXISTS deliveries_timestamp ON deliveries(timestamp);
CREATE INDEX IF NOT EXISTS deliveries_fingerprint ON deliveries(fingerprint);
CREATE INDEX IF NOT EXISTS invocations_timestamp ON invocations(timestamp);
CREATE INDEX IF NOT EXISTS invocations_project ON invocations(project);
'@,
    # 4: the recall store (complete outputs, compressed and masked) and the reads of its entries.
    @'
CREATE TABLE IF NOT EXISTS recalls(id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, invocation TEXT NOT NULL, label TEXT, route TEXT, project TEXT NOT NULL, outcome TEXT NOT NULL, exit_code INTEGER, stdout BLOB, stderr BLOB, stdout_bytes INTEGER NOT NULL, stderr_bytes INTEGER NOT NULL, complete INTEGER NOT NULL, masked INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS recall_reads(id TEXT PRIMARY KEY, recall TEXT NOT NULL, timestamp TEXT NOT NULL, mode TEXT NOT NULL, bytes INTEGER NOT NULL, tokens INTEGER);
CREATE INDEX IF NOT EXISTS recalls_timestamp ON recalls(timestamp);
CREATE INDEX IF NOT EXISTS recalls_invocation ON recalls(invocation);
CREATE INDEX IF NOT EXISTS recall_reads_recall ON recall_reads(recall);
'@,
    # 5: links looked up by invocation (local volume, recall and shadow joins), which the primary key cannot serve.
    'CREATE INDEX IF NOT EXISTS delivery_invocations_invocation ON delivery_invocations(invocation);',
    # 6: what a call costs in time, phase by phase (milliseconds), and the records an invocation framed. Earlier rows
    # keep nulls: elapsed is unchanged, so the gain history reads them as before.
    @'
ALTER TABLE invocations ADD COLUMN setup_ms REAL;
ALTER TABLE invocations ADD COLUMN process_ms REAL;
ALTER TABLE invocations ADD COLUMN callback_ms REAL;
ALTER TABLE invocations ADD COLUMN backpressure_ms REAL;
ALTER TABLE invocations ADD COLUMN complete_ms REAL;
ALTER TABLE invocations ADD COLUMN capture_ms REAL;
ALTER TABLE invocations ADD COLUMN tokens_ms REAL;
ALTER TABLE invocations ADD COLUMN records INTEGER;
ALTER TABLE deliveries ADD COLUMN total_ms REAL;
ALTER TABLE deliveries ADD COLUMN recall_ms REAL;
ALTER TABLE deliveries ADD COLUMN format_ms REAL;
ALTER TABLE deliveries ADD COLUMN tokens_ms REAL;
ALTER TABLE deliveries ADD COLUMN import_ms REAL;
'@,
    # 7: the writes to the history a delivered call made before its delivery's own (its invocations and recall).
    'ALTER TABLE deliveries ADD COLUMN storage_ms REAL;'
)

function Update-OP2Schema {
    # Applies the pending migrations in one immediate transaction; a newer schema is never downgraded.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Internal step of every measurement storage access; the history it migrates belongs to the engine.')]
    [CmdletBinding()]
    param([object]$Command)
    $latest = $script:OP2Migrations.Count
    $Command.CommandText = 'PRAGMA user_version;'
    $schema = [long]$Command.ExecuteScalar()
    if ($schema -gt $latest) { throw 'The measurement database schema is newer than this engine.' }
    if ($schema -eq $latest) { return }
    $Command.CommandText = 'BEGIN IMMEDIATE;'
    [void]$Command.ExecuteNonQuery()
    try {
        # Another process may have migrated the database while this one waited for the lock.
        $Command.CommandText = 'PRAGMA user_version;'
        for ($index = [long]$Command.ExecuteScalar(); $index -lt $latest; $index++) {
            $Command.CommandText = $script:OP2Migrations[$index]
            [void]$Command.ExecuteNonQuery()
        }
        $Command.CommandText = "PRAGMA user_version=$latest; COMMIT;"
        [void]$Command.ExecuteNonQuery()
    } catch {
        $Command.CommandText = 'ROLLBACK;'
        [void]$Command.ExecuteNonQuery()
        throw
    }
}
