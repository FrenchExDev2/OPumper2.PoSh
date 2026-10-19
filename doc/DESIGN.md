# Responsibilities

The public entry points coordinate small components: command-line parsing, configuration, process execution, framing/dispatch, completion objects, obfuscation, serialization, measurement, storage, schema migrations, registry, the gain report (query, aggregation, advice, rendering) with its maintenance, and the [declarative filter](FILTERS.md) interpreter (definitions, contract, summary, catalogue page, registration). The engine contains no Git or dotnet interpretation, and no filter catalogue: catalogues are data that ecosystem modules ship and register.

Extension points are ordered tables, so a new case appends one entry without editing their consumers: schema migrations (`Schema.ps1`), gain keys (`Gain.Aggregate.ps1`), advice rules (`Gain.Advice.ps1`) and report renderers (`Gain.Render.ps1`). Text tables and CSV share one row projection; totals, groups and history entries share one measure.

`pump` is a simple function, so PowerShell binds none of its arguments: it reads its options up to the command, passes the rest verbatim and splats the result into the advanced `Pump-Me`. Native options therefore never collide with `Pump-Me` parameters. PowerShell still removes the first `--` before any function receives its arguments; `pump` finds it in the statement's syntax tree and fails when it followed the command, since it cannot be restored.

Obfuscation is an ordered middleware list applied during the recursive protection walk, before serialization. Pattern entries execute as .NET regular expressions; only script entries invoke PowerShell. The pipe fails closed. Engine metadata bypasses it, except error messages and failure excerpt lines, which carry native or exception text.

Delivery saves the recall, projects and protects a copy of the completion, applies its budget, then counts and stores the final text. `Yaml.ps1` owns YAML loading and scalar typing; `Protection.ps1` owns recursive protection; `Delivery.ps1` builds the view and coordinates `Budget.ps1`. Budget stages reduce records, Data, excerpts and metadata in that order. Each mutation refreshes the serialized text and its UTF-8 byte count. Compaction happens at text conversion because truncation accounting needs the complete metadata.

`Options.ps1` resolves format and limits once, preserving explicit zero values. `Context.ps1` gives each pump or task invocation a scope. Nested scopes share the outer account (storage durations, pending native entry and stores), while retaining their own task membership and configuration snapshot. An unchanged substitute environment inherits the snapshot; a nested `Use-OPumper2Environment` resolves its own. Every exit restores the parent, including exceptions. Only the runspace's current-scope pointer is ambient; the native call also receives its scope explicitly. Session registries and immutable caches have separate lifetimes.

`Storage.ps1` obtains stores by canonical database path from the account, using case-sensitive keys on Unix. Nested calls can share several databases without replacing their parent's connection. SQL failures dispose the affected store and roll back its transaction; outer exit disposes all remaining stores. `Get-OP2Timestamp` is the monotonic duration boundary, and `Get-OP2UtcNow` supplies UTC history timestamps independently.

`New-OP2Execution` supplies the common execution fields. Native calls add stream sizes, records, finalizer errors and phase timings; tasks add steps and issues; replay adds its recall ID and record count. A missing duration stays null, and inapplicable native fields stay absent. The public completion shape and delivered compaction remain unchanged.

Callbacks are the domain boundary. Contributors depend on the public engine API; the engine never imports contributors. Importing a contributor is separate from registering its routes and from executing its observations.

Shared serializers, budgets and measurement sessions are implemented once. Unit tests replace process/storage boundaries where appropriate; integration tests execute real synthetic processes and local databases. Avoid abstractions with no independent responsibility or test boundary.

The native runner uses asynchronous .NET stream reads from PowerShell. It drains both streams through EOF, scopes environment changes to the child, and owns its temporary captures. It does not run PowerShell callbacks on background threads.

The C# engine assembly (`engine/`, built into `resources/runtime`) reads no environment variable and no configuration. The PowerShell layer resolves them, through the runspace-local substitute that isolates concurrent hosts, and passes values in: the child's variables on the start info `pump -Environment` builds, and every limit, encoding and input as arguments.
