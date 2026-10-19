# Validation evidence — 2026-10-16

The validated matrix is the latest stable PowerShell Core on Windows and on Linux (see [quality](QUALITY.md)). Each package is evaluated independently, with the pinned tools and the complete production source set. There are no skipped tests, discovery errors or analyzer diagnostics.

## Current revision (command line, failure excerpts, compact delivery)

| Platform | PowerShell | Mutation workers | Engine tests | Git tests | Coverage, each package | Engine mutations | Git mutations |
|---|---|---:|---:|---:|---:|---:|---:|
| Windows 11 | 7.6.7 | 0 (11 on 12 cores, default) | 87/87 | 14/14 | 100% | 379/379 (100%) | 57/57 (100%) |
| Linux, Podman (Alpine 3.24, musl) | 7.6.7 | — | not run | not run | — | — | — |

**Linux is not validated for this revision.** The image built, but Podman 6.1.2 could not start any container, not even a trivial one: `crun: controller 'pids' is not available under /sys/fs/cgroup/non-systemd/machine.slice/...`. Since the WSL virtual machine started at 11:29 (WSL 3.0.3.0, kernel 6.18.54.1), the machine's systemd runs below `/sys/fs/cgroup/non-systemd`, whose controllers are not delegated to its children; restarting the Podman machine reproduces it. The Alpine runs below apply to the previous revision only.

The engine keeps its four individually justified equivalent declarations, all still matched; Git has none. `timedOut` is 0 in both reports and engine mutation took 344 s. Source SHA-256 values in the accepted reports match the current 18 engine and four Git production files.

**Load-dependent kill removed.** One run reported the idle-polling equivalence (`Wait-OP2Read` 2 → 3 ms) as killed. The killing test gave a child process one second to start and write before its timeout, which eleven workers starving the CPU could exceed. The test now allows five seconds. The accepted run uses that margin.

| Run | Engine artifacts | Git artifacts |
|---|---|---|
| Windows 7.6.7, default workers | [summary](../test/Artifacts/windows/7.6.7/a8163b717f254b9db2af4d2ea304c29a/summary.json) | [summary](../../FrenchExDev.OPumper2.Git.PoSh/test/Artifacts/windows/7.6.7/a8163b717f254b9db2af4d2ea304c29a/summary.json) |

The [command-line example](../examples/CommandLine.ps1) delivered a failed completion with `ExitCode: 2`, the last three stdout lines and the stderr line with its token masked, without any stdout line in `Data`. The [direct example](../examples/Direct.ps1) returned one successful completion with both stream counters, and the [obfuscation example](../examples/Obfuscation.ps1) delivered its observation without the planted credentials, token, e-mail address or host name. A routed `pump git status` outside a repository delivered 494 bytes of YAML holding exit code 128 and Git's `fatal: not a git repository` line, which the previous delivery format omitted. These functional observations are separate from comparative performance benchmarks.

## Previous revision: parallel equivalence

These runs validated the previous source revision (before the command-line form and failure excerpts) on both platforms. Their reports no longer match the current sources; they remain the evidence that parallel mutation workers produce the same verdicts as a serial run.

| Platform | PowerShell | Mutation workers | Engine tests | Git tests | Engine mutations | Git mutations |
|---|---|---:|---:|---:|---:|---:|
| Windows 11 | 7.6.7 | 1 | 79/79 | 14/14 | 303/303 | 57/57 |
| Windows 11 | 7.6.7 | 6 | 79/79 | 14/14 | 303/303 | 57/57 |
| Windows 11 | 7.6.7 | 0 (11, default) | 79/79 | 14/14 | 303/303 | 57/57 |
| Linux, Podman (Alpine 3.24, musl) | 7.6.7 | 6 | 79/79 | 14/14 | 303/303 | 57/57 |
| Linux, Podman (Alpine 3.24, musl) | 7.6.7 | 0 (11, default) | 79/79 | 14/14 | 303/303 | 57/57 |

The serial and six-worker Windows reports were compared mutant by mutant (file, function, line, operator, description, identifier and verdict): the 303 engine and 57 Git mutants are identical, with no mutant present on one side only. The Alpine six-worker reports and both default-worker reports are also identical to the Windows serial reports. Durations of the full gate: Windows 20 min 32 s serial, 8 min 19 s with six workers and 7 min 47 s with the default; Alpine 6 min with six workers and 6 min 18 s with the default, image build included.

The first default-worker control run on Windows stalled on one mutant (`Native.ps1` read filter `-and` → `-or`), which made the read loop wait synchronously and, under heavy load, deadlocked the stdin test. The timeout test now runs first in `Native.Tests.ps1`, so this mutant always fails an assertion within seconds.

| Run | Engine artifacts | Git artifacts |
|---|---|---|
| Windows 7.6.7, serial | [summary](../test/Artifacts/windows/7.6.7/c3b93d4ff3b043aab47a4979ffddd167/summary.json) | [summary](../../FrenchExDev.OPumper2.Git.PoSh/test/Artifacts/windows/7.6.7/c3b93d4ff3b043aab47a4979ffddd167/summary.json) |
| Windows 7.6.7, 6 workers | [summary](../test/Artifacts/windows/7.6.7/0484c865285f40c798600b4d5f682a23/summary.json) | [summary](../../FrenchExDev.OPumper2.Git.PoSh/test/Artifacts/windows/7.6.7/0484c865285f40c798600b4d5f682a23/summary.json) |
| Windows 7.6.7, default workers | [summary](../test/Artifacts/windows/7.6.7/1ef459341d0341559f334dba07730de6/summary.json) | [summary](../../FrenchExDev.OPumper2.Git.PoSh/test/Artifacts/windows/7.6.7/1ef459341d0341559f334dba07730de6/summary.json) |
| Alpine 7.6.7, 6 workers | [summary](../test/Artifacts/linux/stable/FrenchExDev.OPumper2.PoSh/linux/7.6.7/105e4e038cc84933a56b3362de5b2611/summary.json) | [summary](../test/Artifacts/linux/stable/FrenchExDev.OPumper2.Git.PoSh/linux/7.6.7/105e4e038cc84933a56b3362de5b2611/summary.json) |
| Alpine 7.6.7, default workers | [summary](../test/Artifacts/linux/stable/FrenchExDev.OPumper2.PoSh/linux/7.6.7/9f12c44537444d53be57754bacfa54b5/summary.json) | [summary](../test/Artifacts/linux/stable/FrenchExDev.OPumper2.Git.PoSh/linux/7.6.7/9f12c44537444d53be57754bacfa54b5/summary.json) |

Podman executed the Linux suites in a container with networking disabled; reports were copied before the owned container was removed and the build context was deleted by the launcher. The Alpine base image digest is recorded in `test/container-images.lock.json`; the PowerShell version and the musl archive SHA-256 verified during the image build are in `test/runtime-versions.psd1`. The CI workflow invokes the same launchers.

## Five packages, Windows (2026-10-18)

After the recall store, filters and agent integration, each package ran `Invoke-Tests.ps1 -Suite All -Analyze -Mutation` (default workers) on Windows 11, PowerShell 7.6.7. The Linux/Podman matrix above has not been rerun for this revision.

| Package | Tests | Coverage | Analyzer | Mutation | Report |
| --- | --- | --- | --- | --- | --- |
| Engine | 141 | 100 % | 0 | 680/680, 10 declared equivalents | [summary](../test/Artifacts/windows/7.6.7/b8d2946ad29f4db7aa005d4632b5ee62/summary.json) |
| Git | 15 | 100 % | 0 | 57/57 | [summary](../../FrenchExDev.OPumper2.Git.PoSh/test/Artifacts/windows/7.6.7/1fbe18f30fdf4cfb8c5555f69e155660/summary.json) |
| Dotnet | 27 | 100 % | 0 | 37/37 | [summary](../../FrenchExDev.OPumper2.Dotnet.PoSh/test/Artifacts/windows/7.6.7/5931f8adf09243e68b291382350bacbe/summary.json) |
| Filters | 25 | 100 % | 0 | 47/47 | [summary](../../FrenchExDev.Filters.OPumper2.PoSh/test/Artifacts/windows/7.6.7/967eeed3c22b4f6b8fe2d509e6b81028/summary.json) |
| Agent | 30 | 100 % | 0 | 152/152 | [summary](../../FrenchExDev.OPumper2.Utility.Agent.PoSh/test/Artifacts/windows/7.6.7/09ce92b2554d4ca18430039288b569a9/summary.json) |

The Git run predates two added lines in its test support (unloading the Filters and Agent modules). A bypass test used to swap `[Console]::Out`, which every runspace of the process shares, so parallel mutation workers could read each other's output and a mutant could be killed in one run and survive in the next; bypass now writes through writers substituted per runspace. A real monorepo build through the dotnet route is recorded in [the dotnet workspace example](../../FrenchExDev.OPumper2.Dotnet.PoSh/doc/WORKSPACE-EXAMPLE.md).
