function Get-OP2PathComparer {
    param([bool]$CaseSensitive = !$IsWindows)
    if ($CaseSensitive) { return [StringComparer]::Ordinal }
    return [StringComparer]::OrdinalIgnoreCase
}

# The databases whose schema this process checked: once per database, and again for a file that did not exist yet.
$script:OP2PathComparer = Get-OP2PathComparer
$script:OP2SchemaReady = [Collections.Generic.HashSet[string]]::new($script:OP2PathComparer)

function New-OP2Connection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates a closed database connection; no database is opened or changed.')]
    param([string]$Path)
    $builder = [Microsoft.Data.Sqlite.SqliteConnectionStringBuilder]::new()
    $builder['Data Source'] = $Path; $builder['Default Timeout'] = 1; $builder['Pooling'] = $false
    return [Microsoft.Data.Sqlite.SqliteConnection]::new($builder.ToString())
}

function Open-OP2Connection {
    # An open connection to the history at Path, in WAL mode with foreign keys, its schema migrated.
    param([string]$Path)
    $fresh = ![IO.File]::Exists($Path)
    $connection = New-OP2Connection $Path
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandText = 'PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;'
            [void]$command.ExecuteNonQuery()
            if ($fresh -or !$script:OP2SchemaReady.Contains($Path)) {
                Update-OP2Schema $command
                [void]$script:OP2SchemaReady.Add($Path)
            }
        } finally { $command.Dispose() }
    } catch { $connection.Dispose(); throw }
    return $connection
}

function Get-OP2Store {
    param([string]$Path, [object]$Context = $script:OP2CurrentCall)
    if ($Context -and $Context.Account.Stores.ContainsKey($Path)) { return $Context.Account.Stores[$Path] }
    $store = [pscustomobject]@{ Path = $Path; Connection = Open-OP2Connection $Path
        Owner = $(if ($Context) { $Context.Account }) }
    if ($Context) { $Context.Account.Stores.Add($Path, $store) }
    return $store
}

function Close-OP2Store {
    # Disposal also rolls back a transaction left open by a failed statement.
    param([object]$Store)
    try { $Store.Connection.Dispose() }
    finally { if ($Store.Owner) { [void]$Store.Owner.Stores.Remove($Store.Path) } }
}

function Invoke-OP2Sql {
    param([hashtable]$Configuration, [string]$Sql, [hashtable]$Parameters = @{}, [switch]$Read,
        [object]$Context = $script:OP2CurrentCall)
    Initialize-OP2Dependency
    $path = [IO.Path]::GetFullPath($Configuration.DatabasePath)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $store = Get-OP2Store $path $Context
    $connection = $store.Connection
    $command = $null; $reader = $null
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $Sql
        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            if ($null -eq $value) { $value = [DBNull]::Value }
            [void]$command.Parameters.AddWithValue("@$key", $value)
        }
        if ($Read) {
            $reader = $command.ExecuteReader()
            # Names are read once and each row copies its values in one call: per-field reader calls cost five times more.
            $names = [string[]]::new($reader.FieldCount)
            for ($index = 0; $index -lt $names.Length; $index++) { $names[$index] = $reader.GetName($index) }
            $values = [object[]]::new($names.Length)
            while ($reader.Read()) {
                [void]$reader.GetValues($values)
                $row = [ordered]@{}
                for ($index = 0; $index -lt $names.Length; $index++) {
                    $value = $values[$index]
                    $row[$names[$index]] = $(if ($value -is [DBNull]) { $null } else { $value })
                }
                [pscustomobject]$row
            }
        } else { [void]$command.ExecuteNonQuery() }
    } catch {
        # A failed statement may leave a transaction open: the shared connection is dropped with it, and its readers.
        if ($Context) { Close-OP2Store $store }
        throw
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($command) { $command.Dispose() }
        if (!$Context) { Close-OP2Store $store }
    }
}
