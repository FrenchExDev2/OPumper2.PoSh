# Obfuscation pipe

Every JSON/YAML delivery (`Pump-Me`, `Invoke-OPumper2Task`, `ConvertTo-OPumper2Output`, `Out-OPumper2`, `Get-OPumper2Gain`) walks the delivered records, the completion's `Data`, the failure excerpt lines and the error messages through an ordered, process-local list of middlewares. Other engine metadata (`Kind`, `Outcome`, `Execution`, `Truncation`, `Error.Code`, ...) is not obfuscated. `AsObject` values are never transformed: local objects keep their shape, including the raw `Capture` and `Error.Message`.

## Built-ins

They run first, in this order, and cannot be unregistered.

| Id | Effect |
|---|---|
| `builtin.secret-keys` | Value of a key named `password`, `passwd`, `secret`, `token`, `api_key`, `authorization`, `credential` or `environment` → `[REDACTED]` |
| `builtin.secret-assignments` | `password=…`, `token: …`, `Authorization: Basic …` in text → `…=[REDACTED]` |
| `builtin.bearer` | `Bearer <token>` in text → `Bearer [REDACTED]` |
| `builtin.url-credentials` | `scheme://user:pass@host` or `scheme://token@host` → `scheme://[REDACTED]@host` |

## Adding a middleware

Patterns are case-insensitive .NET regular expressions and run without invoking PowerShell code; prefer them.

```powershell
Register-OPumper2Obfuscator -Id my.host -KeyPattern '^(host|hostname)$'                        # whole value → [REDACTED]
Register-OPumper2Obfuscator -Id my.email -TextPattern '[\w.+-]+@[\w-]+\.[\w.]+' -Replacement '[EMAIL]'
Register-OPumper2Obfuscator -Id my.path -Middleware {
    param($value, $context)
    if ($context.Path -eq 'Data.Home' -and $value -is [string]) { '~' }
} -Before builtin.secret-keys
```

A script middleware receives `$value` (after previous middlewares) and `$context`:

- `Key`: property or dictionary key; `$null` for array items and record roots. Each excerpt line has the key of its stream (`Stdout` or `Stderr`), so `-KeyPattern '^stderr$'` hides delivered stderr lines.
- `Path`: `[i]` for the i-th delivered record, `Data` for the completion data, then `.Name` and `[i]` segments (`[0].Remote.Url`, `Data.Files[3]`). Excerpt lines are `Excerpt.Stdout[i]` or `Execution.Issues[n].Excerpt.Stderr[i]`; messages are `Error.Message`, `Execution.FinalizerError.Message` or `Execution.Issues[n].Error.Message`.
- `Depth`: recursion depth used by the depth limit (0 for excerpt lines).

Output rule: **no output keeps the value, one output replaces it** (emit `,$collection` to replace with a collection; `$null` is a valid replacement). The resulting value is then walked, so children are visited too. More than one output, an exception or any diagnostic stream (`Write-Error`, `Write-Warning`, `Write-Information`) fails closed: the value becomes `[OBFUSCATION FAILED]`, later middlewares are skipped for it and the completion reports `Truncation.Reasons += ObfuscationFailed`.

Middlewares run in list order. Registration appends; `-Before <id>` inserts before an existing entry (built-ins included). `Get-OPumper2Obfuscator` lists `Id`, `Kind` (`Key`, `Text`, `Script`) and `Position`. `Unregister-OPumper2Obfuscator <id>` returns whether something was removed. Identifiers are unique and the `builtin.` prefix is reserved.

A script middleware costs a PowerShell invocation per visited value (about 0.1 ms), so keep large `Data` projections compact or use patterns. Middlewares must be pure: they are not a place for I/O.

See [the executable example](../examples/Obfuscation.ps1).
