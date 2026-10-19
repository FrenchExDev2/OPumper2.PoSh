# Registry

`Register-OPumper2 -Id <id> -Route <string[]> -Handler <scriptblock> -ProviderId <name> [-Priority <int>]` registers a process-local route. The handler receives the resolved call (the `Pump-Me` parameters, with an absolute `WorkingDirectory`) and must return objects, ending in a completion object.

A handler provides its own delivered projection through the Result pattern: `New-OPumper2Result -Completion (Pump-Me ... -AsObject) -Projection { param($data, $settings) ... }`. `-AsObject` returns the complete domain value and capture; JSON and YAML deliver the projection, sized with `$settings.MaxItems` and `$settings.MaxOutputBytes`. See [the contract](../CONTRACT.md).

Handlers capture module-private references with `.GetNewClosure()`. Registration executes no binary and writes no catalogue. Registering the same Id, route and provider again has no effect (not even on the handler), so every contributor's `Register-<Name>OPumper2` may run twice. A route already taken goes to a strictly higher `-Priority` (0 by default): the registration names the route it took over in `Replaced`; an equal or lower priority, or an Id already used for another route or provider, is refused. `Unregister-OPumper2` removes a route; `Resolve-OPumper2Command` explains the longest matching token prefix, with its `Priority`, without execution.

An unresolved route returns `Unsupported`. The AI can instead provide a direct contract. Contributor activation is explicit:

| Module | Registration | Routes |
| --- | --- | --- |
| [Git](../../FrenchExDev.OPumper2.Git.PoSh/README.md) | `Register-GitOPumper2` | `git status`, then the Git catalogue (`diff`, `log`, `commit`, `push`...) |
| [dotnet](../../FrenchExDev.OPumper2.Dotnet.PoSh/README.md) | `Register-DotnetOPumper2` | `dotnet build`, `test`, `restore`, `pack`, `publish`, `clean` |
| Ecosystem catalogues | `Register-<Name>OPumper2` | declarative filters of Node, Python, Rust, Go, Make, Jvm, Containers, Kubernetes, Systemd, GitHub, Terraform and Search, read by the engine's [filter interpreter](FILTERS.md), skipping routes already taken with the same or a higher priority |
| [Agent](../../FrenchExDev.OPumper2.Utility.Agent.PoSh/README.md) | `Import-OPumper2Workspace` | imports and registers the modules above, in that order, each with its configured priority |

Every contributor's `Register-<Name>OPumper2` takes `-Priority`, passed to the registry: the configured priority of a pump settles the routes two pumps both claim, whatever their loading order.

## Contributor API

A contributor builds on these instead of re-implementing execution, delivery or measurement:

- `Invoke-OPumper2Route -Call $call -Contract $contract [-Explained { param($report) ... }]`: runs a contract object (`ArgumentList`, `Environment`, `State`, `OnRecord` and optionally `OnBatch`, which it prefers, `Complete`, `Projection`, optional `SuccessExitCodes`) for a routed call and returns its Result; when `Explained` returns true for a failed run, the delivery carries no excerpt.
- `Limit-OPumper2Projection`: bounds named lists of a projection (see [the contract](../CONTRACT.md)).
- `ConvertTo-OPumper2Line $text [-Limit 400]`: one delivered line, whitespace flattened and cut with an ellipsis.
- Pumps of the user's configuration (`~/.opumper2/config.yaml`, section `pumps`), which `Import-OPumper2Workspace` loads by descending `priority`, then file order. Each entry has a unique `name`, exactly one of `path` (the module folder) and `module` (a module name or manifest path), `enabled` (default true) and an optional integer `priority`.
  - `New-OPumper2Configuration [-Path] [-Force]` creates the file from the pump modules next to the engine: dedicated contracts first, then the catalogues.
  - `Get-OPumper2Pump [-Name]`, `Add-OPumper2Pump -Name -Path|-Module [-Disabled] [-Priority]`, `Remove-OPumper2Pump`, `Enable-OPumper2Pump` and `Disable-OPumper2Pump` manage the list; each honours `-WhatIf`.
  - `Repair-OPumper2Configuration [-Apply]` proposes, for each missing folder, the module that replaced it (`FrenchExDev.Pnpm.OPumper2.PoSh` → `FrenchExDev.OPumper2.Node.PoSh`), its removal when another entry already loads that module, or disabling it.
  - A rewritten file keeps its `general` settings but not its comments.
- `Format-OPumper2Report $result $PSBoundParameters`: delivers a report Result by its caller's `-AsObject`/`-AsJson`/`-AsYaml` switches, obfuscated and compacted like a delivery, never measured.
- `Measure-OPumper2Token $text`: tokens under the configured tokenizer.
- `Get-OPumper2Configuration`: the effective configuration.
- `Use-OPumper2Environment @{ ... } [{ ... }]`: the engine environment of this runspace (database, configuration, switches), for a block or until the next call; a contributor's tests isolate their history with it rather than reaching into the engine (see [measurement](MEASUREMENT.md)).
