# Quality gates

Each package has independent unit/integration suites, analyzer settings and mutation configuration. Shared scripts are under the engine's `test` directory.

`test/Invoke-Tests.ps1 -Package All -Suite All` runs Pester and coverage. Add `-Analyze` and `-Mutation` for the full gate. Several packages run in parallel by default:

- **Checks:** each package runs Pester, coverage, the analyzer and, for the engine, the xUnit suite in its own process, at most `-ThrottleLimit` at a time (default: processor count).
- **Mutation:** packages then mutate one at a time (PSMutant, then Stryker.NET for the engine), since each mutation run already uses every core.
- **Results:** each process delivers its compact summary through pump; the parent merges the mutation part into each package's `summary.json` and prints one ASCII line.
- **`-Serial`:** keeps everything in one process, in order.

A package's Pester run stays serial: its integration tests start real processes and measure durations, and coverage needs a single run. `test/Invoke-LinuxTests.ps1` runs the same validation in Podman for the pinned stable PowerShell.

The validated matrix is the latest stable PowerShell Core on Windows and on Linux, with the full gate (mutation included) on both. The supported minimum is PowerShell Core 7.6 (manifests and `#requires`); Windows PowerShell 5.1 is not supported.

Pinned tools: Pester 6.2.0, PSMutant 0.6.0, PSScriptAnalyzer 1.25.0, powershell-yaml 0.4.12. Upgrade the dependency manifest deliberately after checking current stable releases; CI never silently changes tools.

Required per package: all tests pass, 100% production PowerShell coverage, 100% mutation score without sampling, and zero unjustified analyzer warnings/errors. Empty discovery, failed baseline, stale equivalent declarations and tool errors fail validation. Narrow documented exceptions only; `Pump-Me` needs the approved-verb exception because its public name is required.

Catalogue packages (Node, Python, Rust, Go, Make, Jvm, Containers, Kubernetes, Systemd, GitHub, Terraform, Search) hold filter data and a loader whose only code locates and registers their catalogue: no `src` folder and no operator to mutate. They have no mutation configuration and report `Mutation.Applicable = false` (`CatalogueData`); their tests cover the loader and run the shared catalogue suite: the tests built into every filter (each filter carries at least one), each entry, route and the generated catalogue page. A package with a `src` folder and no mutation configuration fails validation (`MissingConfiguration`).

## Engine assembly

The C# engine (`engine/`: `Framer`, `NativeRun`, `NativeCapture`, `Record`) has its own gate, with the same bar as the PowerShell code: the xUnit suite (`engine/FrenchExDev.OPumper2.Engine.Tests`, xUnit 2.9.3, coverlet) passes with 100% line and branch coverage, and Stryker.NET 4.16.0 (local tool pinned in `engine/dotnet-tools.json`) reaches a 100% mutation score with `--break-at 100`. Timed-out mutants count as killed. An equivalent mutant is declared on its line with `// Stryker disable once <Mutator> : <reason>`, as narrowly as PSMutant equivalents; the two annotations of the abandon safety net in the pump loop are the only ones.

`test/Invoke-Tests.ps1 -Package Engine` (or `All`) runs this gate after the Pester suites and reports it as `Assembly` in the engine's summary: test counts, `LineRate` and `BranchRate` from the TRX and Cobertura reports, and with `-Mutation` the Stryker.NET score with its first undetected mutants. `test/Invoke-Dotnet.ps1` runs dotnet with English messages and UTF-8 console output, which pump's strict decoder requires on a localized Windows. `-EngineRuntime` chooses where dotnet runs: `Auto` (the default) uses the host's SDK, else the pinned SDK container of the build module (Podman or Docker; it restores with network, then tests offline, the run's artifacts mounted writable); `Host` and `Container` force one. The report names its `Runtime`. With neither, the gate reports `Reason = DotnetUnavailable` (or, for `Container`, why no container could run) and fails. The Linux test image carries the SDK (`dotnet10-sdk`) and restores the engine and its local tools while it is built, so the gate runs there with the network disabled.

Tests start real `pwsh` children (`sh` for the Linux-only cases), each owning its spool files; they cover both streams, the exact environment of the start info, input, strict decoding across reads, spool failures, the bounded queue, killing the whole process tree and abandoning streams a grandchild holds open.

The .NET builds go through `build/FrenchExDev.OPumper2.Build.psm1`, which the engine package's gate covers like its sources:

- `Resolve-OP2BuildRuntime` lists Podman, Docker, then the host's dotnet; `Resolve-OP2BuildTarget` picks the first one that can run, with its pinned image, and names the ones passed over (`Container` never falls back to the host).
- `Get-OP2LockedImage` pins `mcr.microsoft.com/dotnet/sdk:10.0` by digest in `build/container-images.lock.json`; `-UpdateImages` pins it again.
- `Invoke-OP2Dotnet` mounts the package read-only, with `.cache` (and `resources/runtime` for the runtime dependencies) writable and NuGet packages in `.cache/nuget`; the network is reachable only during restores. `-WorkingDirectory` runs it in a folder of the package, such as `engine`, whose local tool manifest Stryker.NET needs.
- `Invoke-OP2BuildProcess` goes through pump when the engine is loaded, and otherwise reads the process directly, since the first build precedes the engine.

Builds and mutation runs write under `.cache/engine`. The module imports a temporary copy of the engine assembly identified by its content hash, leaving `resources/runtime/FrenchExDev.OPumper2.Engine.dll` available for rebuilds. `build/Initialize-Dependencies.ps1` copies the build there only when it changed. Run validation in a fresh PowerShell process to load the rebuilt assembly; an existing process retains its loaded types. Agent build and test commands still go through pump.

## Performance baseline

`test/Measure-OP2Performance.ps1` times real calls in fresh PowerShell processes, as agent tool calls run them, each with its own measurement database: a routed `git status` (imports, workspace, first and second call), a 20,000-line output (first, second and untracked calls, recall grep and replay, shadow dotnet contract), a 5,000-item `Data` (YAML and JSON) and the gain report over 20,000 deliveries. It prints one JSON line per scenario; compare runs on the same machine before and after a change. `-Lines` (up to 1,000,000) sizes the line scenario; `-Paths` fills the routed scenario's repository with that many files, half committed and one in two of those modified, the rest untracked, so `git status` reads a real porcelain listing.

`test/Measure-OP2Dispatch.ps1` measures, per thousand records, what handing records to callbacks costs: one diagnostic check per record, one per batch, none, and a batch callback, against the Git status parser alone. `engine/FrenchExDev.OPumper2.Engine.Benchmarks` (BenchmarkDotNet, outside the engine solution; `dotnet run -c Release` in its folder) measures framing whole and by reads, and counting o200k tokens whole against a candidate newline chunking. That candidate is not exact: `word\n \nfoo` counts 3 tokens whole and 4 split after its first newline, under both o200k and cl100k. The differential xUnit tests retain these counterexamples; the benchmark measures cost and does not authorize streaming counts with that boundary.

Mutation configuration applies the complete default PSMutant expression set (`BinaryOperator`, `BooleanLiteral`, `NegationRemoval`, `NumberLiteral`) to every production PowerShell file, including module loaders, with `coveredLinesOnly: false`. No mutant sampling or global source exclusion is used. The optional additional operator families are not part of this V1 gate. Precise equivalent declarations cover consistent private SQL parameter names, the wait interval of the dispatch loop, excess JSON depth after recursive protection, positional parameter numbers that bind the same argument, and the excerpt window of a successful recall list. Each declaration has its own argument in the package configuration; the tool rejects stale or killed declarations.

Mutation testing changes throwaway sandboxes, not source files. Fixtures and temporary repositories belong to tests. Reports distinguish actual Windows/Linux runs, missing prerequisites, skipped cases and failures. Never declare Linux validated from a host-only or mocked run.

Podman validation stages only the two packages and required test assets. Images contain pinned tools; tests use no network. Collect reports before removing the owned container, including after failure. Record base image digest and actual runtime/tool versions.

The Linux image is Alpine (digest locked in `test/container-images.lock.json`; refresh it with `-UpdateImages`). `test/Containerfile` installs the runtime packages with `apk add --no-cache`, then downloads the official musl PowerShell build named by `PWSH_VERSION` and verifies `PWSH_SHA256`. Both build arguments come from `test/runtime-versions.psd1`, the single place to change when upgrading: `Version` and the release's musl and Windows checksums. The version and checksum are part of the image fingerprint, and the container checks the running version before testing. Artifact directories include platform, runtime and run ID to keep concurrent reports distinct.

The Windows CI job downloads the pinned stable archive and verifies its official SHA-256 value. The runner's preinstalled PowerShell version is not used as the stable-version guarantee.

## Parallel mutation

Both package configurations set PSMutant's `workers` to 0, meaning processor count minus one; CI passes `-Workers 0` explicitly. `Invoke-Tests.ps1 -Workers <n>` and `Invoke-LinuxTests.ps1 -Workers <n>` override it in the staged copy of the package configuration (1 is serial), and omitting it keeps the configured value. The summary records `Mutation.Workers`. Inside the container, workers share the Podman machine's CPUs.

PSMutant workers are runspaces of one process, each with its own sandbox copy, so suites must leave process-wide state alone. Tests never write environment variables: `TestSupport.ps1` installs a runspace-local substitute (`$script:OP2Environment`, read by the engine's configuration), and `Set-TestEnvironment` changes it. Anything else process-wide uses a run-unique name, and child processes that import the module receive an explicit environment. The suites run with a 20-second engine timeout (`test-configuration.yaml` written by `TestSupport.ps1`), so a mutant that stalls an execution fails an assertion within about 25 seconds instead of waiting for PSMutant's deadline, which grows with the worker count. Loops are bounded by construction: reading and framing run in the engine assembly, which PSMutant does not mutate, and the dispatch loop exits after the termination grace period, so no mutant can spin forever. Mutant suites stop at their first failure, so the timeout test runs first in `Native.Tests.ps1`: it kills the mutants of the deadline and termination policy before a slower test waits on them. Timing-sensitive tests keep generous margins because workers compete for CPU. Before relying on a worker count, compare its mutation report with a serial run of the same source mutant by mutant; [validation evidence](VALIDATION.md) records that comparison.

## Cleanup

Launchers own their staging and remove it on every exit path: `Invoke-Tests.ps1 -Mutation` deletes its `.cache/mutations/<id>` sandbox after copying `mutation.json` (a removal failure is reported as `Mutation.StageCleanupError`), and `Invoke-LinuxTests.ps1` deletes its `.cache/linux/<id>` build context once the image is built or reused. Pester suites write only to `$TestDrive`.

Run reports, test images and stray files still accumulate. Apply the retention policy with `test/Clear-TestCache.ps1`, never while a launcher is running:

- `-WhatIf` lists candidates and sizes without removing anything; read it first.
- `.cache` keeps only `Modules` and `dependencies`; everything else (staging, diagnostics, stray databases, obsolete runtime archives) is removed.
- `test/Artifacts` of both packages keeps the `-KeepRuns` newest runs (default 3) per platform/runtime directory plus every run ID cited in a package's `doc/*.md`, such as [validation evidence](VALIDATION.md). Loose legacy files are removed.
- `-Images` also removes `localhost/opumper2-tests` images beyond the `-KeepImages` newest (default 1, the validated stable runtime); the Podman machine must be running. Reported image sizes are apparent sizes: shared layers are freed only once no image uses them.

The script prints one JSON summary (`FreedBytes`, the 50 largest removals, retained and pinned runs).
