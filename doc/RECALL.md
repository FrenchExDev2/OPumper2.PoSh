# Recall store, shadow contracts and bypass

## Recall store

Every JSON or YAML delivery of a native call stores its complete capture in the measurement database, gzip-compressed, and names it in the delivery: `Recall: 4e4bd3021508` (the first 12 hexadecimal digits of the invocation id). An agent that needs more than the contract kept reads the stored output instead of running the command again:

```powershell
Get-OPumper2Recall 4e4bd3021508 -Grep 'error CS\d+'        # matching lines, numbered
Get-OPumper2Recall 4e4bd3021508 -From 120 -Lines 40        # a window of lines
Get-OPumper2Recall 4e4bd3021508 -Stream stderr             # one stream
Get-OPumper2Recall -List                                   # stored recalls, most recent first
Invoke-OPumper2Recall 4e4bd3021508 -OnRecord { param($record, $state) ... }   # replay through another contract
```

A recall read is itself a bounded delivery (`MaxItems`, `MaxOutputBytes`) and is recorded in `recall_reads`, which feeds `Recalled` and `RecallRate` in [the gain report](MEASUREMENT.md#gain-report). `Invoke-OPumper2Recall` replays the stored streams through callbacks exactly as a live run would feed them, so a new contract can be tried on yesterday's output.

Stored text passes through the [obfuscation pipe](OBFUSCATION.md) first (`recallMask: true`). Each entry keeps at most `recallMaxEntryBytes` (10 MiB) per stream, the last bytes when longer; the store keeps `recallMaxEntries` (200) entries and `recallRetentionDays` (30) days, oldest first. `recall: failures` stores failed calls only, `recall: off` or `OPUMPER2_RECALL=0` nothing. `-AsObject` calls are never stored: the local object already holds `Capture`. An unknown or expired id fails with `Unknown recall: <id>.`

## Shadow contracts

`Measure-OPumper2Contract` replays a candidate contract over stored outputs and compares what it would deliver with what was delivered, without delivering anything:

```powershell
Measure-OPumper2Contract -Contract { New-DotnetBuildContract } -Command dotnet -AsText
```

`-Contract` returns a fresh contract per output (`State`, `OnRecord`, `Complete`, optionally `Projection`). `-Recall` selects ids, `-Command` an executable, `-Since` a date. The report gives, per output and in total, the captured, delivered and shadow tokens, `SavedVsDelivered` and `ShadowRate`. It is not itself measured.

## Bypass

`Invoke-OPumper2Bypass <command> [arguments]` is for people at a terminal: it prints the output as is and records it as a delivery of everything printed under the route `bypass`, so the gain history shows what pump would have saved. Agents never use it. It sets `$LASTEXITCODE` like a native command.
