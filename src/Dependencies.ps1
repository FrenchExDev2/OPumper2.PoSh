function Import-OP2EngineAssembly {
    # A checkout imported before its build gets a message naming the build script, not a .NET load failure. The engine
    # loads from a copy named by its content: a session holding the engine then never locks resources/runtime, and a
    # build replaces the assembly whatever terminal has the module open.
    param([string]$Path, [string]$ShadowRoot = (Join-Path ([IO.Path]::GetTempPath()) 'opumper2-engine'))
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The engine assembly is missing ($Path): run build/Initialize-Dependencies.ps1 first." }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.Substring(0, 16)
    $copy = Join-Path $ShadowRoot "$hash/$([IO.Path]::GetFileName($Path))"
    if (!(Test-Path -LiteralPath $copy -PathType Leaf)) { Copy-OP2ShadowFile $Path $copy }
    [void][Reflection.Assembly]::LoadFrom($copy)
    return $copy
}

function Copy-OP2ShadowFile {
    # Concurrent imports may copy at once: each writes its own file, the first move wins and the others drop theirs.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Writes a private copy in the temporary folder.')]
    param([string]$Path, [string]$Copy)
    [void][IO.Directory]::CreateDirectory((Split-Path $Copy))
    $partial = "$Copy.$([guid]::NewGuid().ToString('N'))"
    [IO.File]::Copy($Path, $partial)
    try { [IO.File]::Move($partial, $Copy) } catch [IO.IOException] { [IO.File]::Delete($partial) }
}

function Initialize-OP2Dependency {
    $directory = Join-Path $script:OP2Root 'resources/runtime'
    foreach ($name in @('Microsoft.ML.Tokenizers','Microsoft.ML.Tokenizers.Data.O200kBase','Microsoft.ML.Tokenizers.Data.Cl100kBase','SQLitePCLRaw.core','SQLitePCLRaw.provider.e_sqlite3','SQLitePCLRaw.batteries_v2','Microsoft.Data.Sqlite')) {
        [void][Reflection.Assembly]::LoadFrom((Join-Path $directory "$name.dll"))
    }
    foreach ($encoding in @('o200k_base','cl100k_base')) {
        if (!$script:OP2Tokenizers.ContainsKey($encoding)) {
            # A vocabulary loads on its first count (a quarter of a second): a call counts with one encoding only. Warm
            # starts that load on a background task while the child runs; the first count takes its result.
            $holder = @{ Tokenizer = $null; Pending = $null }
            $counter = {
                param($text)
                if ($null -eq $holder.Tokenizer) {
                    $holder.Tokenizer = $(if ($holder.Pending) { $holder.Pending.GetAwaiter().GetResult() } else { [Microsoft.ML.Tokenizers.TiktokenTokenizer]::CreateForEncoding($encoding, $null, $null) })
                }
                $holder.Tokenizer.CountTokens([string]$text)
            }.GetNewClosure()
            $warm = { if ($null -eq $holder.Tokenizer -and $null -eq $holder.Pending) { $holder.Pending = [FrenchExDev.OPumper2.Engine.TokenizerWarmup]::Start($encoding) } }.GetNewClosure()
            $script:OP2Tokenizers[$encoding] = @{ Version = 'Microsoft.ML.Tokenizers/2.0.0'; Count = $counter; Warm = $warm; Holder = $holder }
        }
    }
    $platform = ([Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier -split '-')[0]
    $architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    $file = @{ win = 'e_sqlite3.dll'; osx = 'libe_sqlite3.dylib'; linux = 'libe_sqlite3.so' }[$platform]
    if (!(Test-Path -LiteralPath (Join-Path $directory $file) -PathType Leaf)) { throw "Prepare the native dependency for $platform-$architecture using Initialize-Dependencies.ps1." }
    # Microsoft.Data.Sqlite initializes its pinned SQLitePCLRaw bundle automatically.
}
