# OPumper2

PowerShell Core 7.6+ output contracts supplied by the AI. The engine executes binaries, drains both streams, invokes callbacks and returns domain objects followed by a completion. It also supplies explicit routing, an extensible obfuscation pipe for delivered output and local SQLite/token measurements.

Start with [AGENTS.md](AGENTS.md), then read only the relevant documentation branch.

```powershell
Import-Module ./FrenchExDev.OPumper2.PoSh.psd1 -DisableNameChecking
# Options first, then the command with its native arguments, unchanged.
pump -OnRecord { param($record, $state) if ($record.Text -match ': error ') { $record.Text } } dotnet build -c Release
```

On failure, the delivery holds the exit code, the error message and the last lines of each stream; the complete output stays on the local object. See [the command-line example](examples/CommandLine.ps1) and [the direct example](examples/Direct.ps1).

Before standalone use, run `build/Initialize-Dependencies.ps1` to prepare the pinned third-party libraries and build the engine assembly. No .NET SDK is required on the machine: `-BuildRuntime Auto` (the default) builds in the pinned SDK image with Podman, then Docker, and uses the host's `dotnet` only when neither can. A container runtime whose image cannot be pulled is skipped and reported. `build/Build-Engine.ps1 [-Runtime Auto|Podman|Docker|Host] [-Project Engine,Dependencies] [-Test]` runs the same builds on their own and prints one compact JSON result. Release packaging must include `resources/runtime` and third-party notices. The runtime has no dependency on the previous OutputPumps engine.

[Git consumer](../FrenchExDev.OPumper2.Git.PoSh/README.md) demonstrates a direct contract and the same observation registered as `pump git status`. [dotnet consumer](../FrenchExDev.OPumper2.Dotnet.PoSh/README.md) registers the `dotnet` build verbs and `dotnet test` with the Result pattern: a complete report locally, a compact projection when delivered. The engine's [filter interpreter](doc/FILTERS.md) reads the declarative catalogues that ecosystem modules (Node, Python, Rust, Go, Make, Jvm, Containers, Kubernetes, Systemd, GitHub, Terraform, Search, and Git beyond `git status`) ship for about 130 other commands. [Agent](../FrenchExDev.OPumper2.Utility.Agent.PoSh/README.md) loads them all in one call, installs a Claude Code hook that reminds, refuses or rewrites shell commands run without pump, and reports what reached the agent without pump.

Each delivery keeps its output in the [recall store](doc/RECALL.md) for reading back without a rerun; `Get-OPumper2Gain` reports the savings ([measurement](doc/MEASUREMENT.md)).

Run [the quality gates](doc/QUALITY.md) on Windows and Linux/Podman. Read generated reports before claiming coverage or mutation thresholds have passed.

See [the recorded validation evidence](doc/VALIDATION.md) for the actual platform matrix and report locations.
