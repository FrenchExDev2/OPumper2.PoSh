# Declarative filters

The engine interprets declarative output filters: a contract written as data, for commands whose output a few line expressions explain. The engine ships no catalogue: each ecosystem module ships its own as data and registers it with `Register-OPumper2Filter -Path <its filters folder>`.

| Module | Registration | Commands |
| --- | --- | --- |
| [Git](../../FrenchExDev.OPumper2.Git.PoSh/README.md) | `Register-GitOPumper2` | `git diff`, `show`, `log`, `branch`, `push`/`pull`/`fetch`/`clone`, `commit`, `merge`/`rebase`/`checkout`..., `grep`, `ls-files`; `git status` keeps its own contract |
| [Node](../../FrenchExDev.OPumper2.Node.PoSh/README.md) | `Register-NodeOPumper2` | npm, pnpm and yarn installs, scripts and audits, jest, vitest, tsc, eslint, Playwright |
| [Python](../../FrenchExDev.OPumper2.Python.PoSh/README.md) | `Register-PythonOPumper2` | pytest, pip and uv pip, ruff, mypy |
| [Rust](../../FrenchExDev.OPumper2.Rust.PoSh/README.md) | `Register-RustOPumper2` | cargo build, check, clippy, run, test, nextest |
| [Go](../../FrenchExDev.OPumper2.Go.PoSh/README.md) | `Register-GoOPumper2` | go build, vet, install, test |
| [Make](../../FrenchExDev.OPumper2.Make.PoSh/README.md) | `Register-MakeOPumper2` | make, ninja, cmake --build |
| [Jvm](../../FrenchExDev.OPumper2.Jvm.PoSh/README.md) | `Register-JvmOPumper2` | Maven, Gradle |
| [Containers](../../FrenchExDev.OPumper2.Containers.PoSh/README.md) | `Register-ContainersOPumper2` | docker and podman ps, images, build, logs, compose included |
| [Kubernetes](../../FrenchExDev.OPumper2.Kubernetes.PoSh/README.md) | `Register-KubernetesOPumper2` | kubectl get, describe, apply/delete/create, logs; helm |
| [Systemd](../../FrenchExDev.OPumper2.Systemd.PoSh/README.md) | `Register-SystemdOPumper2` | journalctl |
| [GitHub](../../FrenchExDev.OPumper2.GitHub.PoSh/README.md) | `Register-GitHubOPumper2` | gh lists, pr checks, run view |
| [Terraform](../../FrenchExDev.OPumper2.Terraform.PoSh/README.md) | `Register-TerraformOPumper2` | terraform and tofu plan, apply/destroy, init/validate |
| [Search](../../FrenchExDev.OPumper2.Search.PoSh/README.md) | `Register-SearchOPumper2` | rg, grep, ag, find, fd, tree, ls |

```powershell
# From the engine folder
Import-Module ./FrenchExDev.OPumper2.PoSh.psd1 -DisableNameChecking
Import-Module ../FrenchExDev.OPumper2.Python.PoSh/FrenchExDev.OPumper2.Python.PoSh.psd1
Register-PythonOPumper2 | Out-Null                     # every Python route not already taken

pump pytest -q                                         # Failed, FailedFiles, session summary, failure lines
$run = pump -AsObject pytest                           # complete report and capture
$run.Data.Kept | Where-Object Occurrences -GT 1
```

`Import-OPumper2Workspace` ([Agent](../../FrenchExDev.OPumper2.Utility.Agent.PoSh/README.md)) registers Git, dotnet and every catalogue module in one call. `Get-OPumper2Filter -Path <folder>` and `Register-OPumper2Filter -Path <folder>` read any catalogue folder, a private one included. `New-OPumper2FilterContract -Definition <definition>` returns a direct contract (arguments, environment, state, `OnRecord`, `Complete`, `Projection`) for local scripts, and `ConvertTo-OPumper2FilterCatalogue <definitions>` the catalogue page of a module.

## Definition contract

A catalogue file is a PowerShell data file (`*.psd1`) holding `Filters = @(...)`. Each entry is a hashtable with these keys; any other key is refused with the file name and filter Id.

| Key | Required | Meaning |
| --- | --- | --- |
| `Id` | yes | Unique name across the catalogue folder, `area.command` by convention, the area being the module's ecosystem. |
| `Routes` | yes | Command lines it answers, as space-separated tokens: `'git log'`, `'python -m pytest'`. The first registered route takes the Id, the others `Id (route)`. |
| `Description` | | What the projection delivers, one sentence. |
| `Source` | | The output format the expressions follow (tool documentation or recorded output). |
| `Arguments` | | Native arguments inserted right after the route tokens, so a later `--` or path keeps its meaning. |
| `Environment` | | Variables set for the run. `NO_COLOR=1` is always set unless overridden. |
| `SuccessExitCodes` | | Exit codes that count as success, `@(0)` by default (`grep` and `rg` use `@(0,1)`). |
| `Drop` | | Expressions of noise lines: a dropped line is only counted in `Dropped`. |
| `Counters` | | `Name = expression`. With `(?<value>\d+)` the counter keeps the last value, with `(?<sum>\d+)` it sums, otherwise it counts matching lines. |
| `Groups` | | `Name = expression` with a `(?<key>...)` capture: lines counted per key. A group cannot take a header name (`Filter`, `Succeeded`, `Lines`, `Dropped`, `Counters`, `Captures`, `Kept`, `Omitted`). |
| `Captures` | | `Name = expression`: the last matching line, or its `(?<text>...)`. |
| `Keep` | | Expressions of lines that explain the result. |
| `Dedupe` | | `$true` by default: a repeated kept line is kept once with its `Occurrences`. `$false` keeps every line in order (listings). |

Expressions are .NET regular expressions compiled culture-invariant and case-sensitive; use `(?i)` where case varies. They match each line after ANSI color and cursor sequences are removed.

## Reading order

For each line: strip colors, count it in `Lines`; if a `Drop` expression matches, count it in `Dropped` and stop. Otherwise every counter, group and capture reads it, then the first matching `Keep` expression keeps it.

## Report and projection

`Complete` returns the report: `Filter`, `WorkingDirectory`, `ExitCode`, `Succeeded` (exit code in `SuccessExitCodes`), `Lines`, `Dropped`, `Counters`, `Groups`, `Captures` and `Kept` (`Text`, `Stream`, `Occurrences`). The local object of `pump -AsObject` holds it as `Data`.

| | Delivered projection | Local object (`-AsObject`) |
| --- | --- | --- |
| Header | `Filter`, `Succeeded`, `Lines` | the same, plus `ExitCode`, `Dropped`, `WorkingDirectory` |
| Counters and captures | non-empty values | every value, `$null` when never matched |
| Groups | entries by descending count then key, bounded by `MaxItems` | every key and count |
| Kept lines | single-spaced, `(xN)` appended for repetitions, bounded | `Text`, `Stream`, `Occurrences` |
| Raw output | `Excerpt` only when no kept line explains a failure | `Capture.Stdout`, `Capture.Stderr` |

Every list keeps at most `MaxItems` entries; then, to fit `MaxOutputBytes`, groups lose their last entries before kept lines do. `Omitted` counts the dropped entries per section. A failed run whose report kept at least one line is explained: its delivery carries no `Excerpt`. A failed run with no kept line keeps the engine's excerpt.

## Registration

`Register-OPumper2Filter -Path <folder> [-Id <ids>] [-Priority <int>]` registers each route under provider `filters`. A route already registered with exactly the same tokens and the same or a higher priority is skipped, so `git status` or `dotnet build` keep their dedicated contracts; a lower priority gives way. A shorter registered prefix does not prevent a longer filter route, since the engine resolves the longest route first. Registering a catalogue again has no effect. The first route of a filter takes its Id, the others `Id (route)`. Duplicate Ids and unknown requested Ids are refused before anything is registered.

## Catalogue modules

A catalogue module holds data and a loader only: its manifest requires the engine, its `filters/` folder holds the entries, and its psm1 exports `Register-<Name>OPumper2 [-Id]`, which calls `Register-OPumper2Filter` with that folder. It has no `src` folder and nothing to mutate (see [quality](QUALITY.md)). Its test file sets `$CatalogueCase` and dot-sources the engine's shared suite (`test/Shared/Catalogue.Shared.ps1`). That suite checks:

- the tests built into its filters, every filter carrying at least one (`RequireAll`);
- that every entry says what it delivers and which format it follows;
- that its routes are distinct and registered;
- that `doc/CATALOGUE.md` equals `ConvertTo-OPumper2FilterCatalogue (Get-OPumper2Filter -Path filters)`.

## Built-in tests

Each entry carries its tests: `Tests = @(@{ Name; Lines; ExitCode; Stream; Expect; Absent })`.

- `Lines` are recorded or documented output lines, read on `Stream` (stdout by default) with `ExitCode` (0 by default).
- `Expect` maps a section of the delivered summary to its text: `Filter`, `Succeeded`, `Lines`, `Kept`, `Counters.<name>`, `Captures.<name>` or `<Group>.<key>`. An array value joins with `|`.
- `Absent` lists sections the summary must not hold (`Kept`, `Counters`, `Captures`, a group, or one entry of them).
- Values are those delivered: lines single-spaced and trimmed by `ConvertTo-OPumper2Line`, repetitions suffixed `(xN)`.
- An unknown key, or a section the filter cannot deliver, is refused when the catalogue loads.

`Test-OPumper2Filter -Path <folder> [-Id] [-RequireAll]` runs them without any process or measurement: one result per test (`Filter`, `Test`, `Passed`, `Failures`, `Warnings`), and one per untested filter (`Untested`), which `RequireAll` fails. A filter with `Keep` needs a successful case and a failing case, judged by its `SuccessExitCodes`: `Warnings` names the missing one (`NoSuccessCase`, `NoFailureCase`) without failing the test. Check what the summary loses: the review of the first tests found four filters dropping the line that explained a failure.

A filter that counts or keeps every line (listings, matches, paths) drops the tool's own error lines (`fatal:`, `rg:`, `find:`, `ls:`, `error:`, `GraphQL:`...) and its "nothing found" messages, so a failure or an empty result counts nothing; the excerpt of a failed call carries the error itself.

A new command format is a new entry, never a new function. Write each expression from the tool's documented output or from recorded real output, and name that format in `Source`. A command whose output needs structure the interpreter cannot express (multi-line records, files the command writes) gets a contract with code in a contributor module, as Git and dotnet do.
