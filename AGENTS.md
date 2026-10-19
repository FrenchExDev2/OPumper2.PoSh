# OPumper2: reading paths

OPumper2 executes a command and the AI's extraction contract. Define the information needed before choosing callbacks. Domain interpretation belongs to the caller or a contributor.

Read only the branch needed for the current task; reuse instructions already read in this session.

| Need | Read |
| --- | --- |
| First use or uncertain execution rules | [RULES.md](RULES.md) |
| Write a direct call or consume its objects | [CONTRACT.md](CONTRACT.md) |
| Find an executable example | [HOW-TO.md](HOW-TO.md) |
| Change the engine | [design](doc/DESIGN.md), then [quality](doc/QUALITY.md) |
| Register or resolve a contributor | [registry](doc/REGISTRY.md) |
| Interpret savings or compose measurements | [measurement](doc/MEASUREMENT.md) |
| Read a delivered output again, try a contract on stored outputs | [recall](doc/RECALL.md) |
| Route many tools without writing a contract, write a filter | [filters and their catalogue modules](doc/FILTERS.md) |
| Load every contributor, hook an agent, find unpumped output | [agent](../FrenchExDev.OPumper2.Utility.Agent.PoSh/README.md) |
| Mask data in delivered output | [obfuscation](doc/OBFUSCATION.md) |
| Run Windows/Linux checks | [quality](doc/QUALITY.md) |
| Free generated test caches, artifacts or images | [quality: cleanup](doc/QUALITY.md#cleanup) |

PowerShell Core 7.6+ only. Call `pump [options] <command> [arguments]` with options before the command; native arguments follow verbatim (`pump -- <command>` when they contain `--`). Read compact structured results; absent fields have their default values. A failed delivery holds the exit code, error message and last lines of each stream (`Excerpt`); every local object, successful or not, keeps the complete output (`Capture`) for your report script. Keep a `-AsObject` result in a variable (`$result = pump -AsObject ...; if ($result.Outcome -ne 'Success') { ... }`) and never write that object to the output: return a chosen field or `$result | Out-OPumper2` ([example](HOW-TO.md)). Handlers return a Result (`New-OPumper2Result`) whose projection is the delivered `Data`. Pass objects between local steps; serialize at the delivery boundary. A route miss never authorizes native passthrough. A delivery's `Recall` id reads its stored output back (`Get-OPumper2Recall <id> -Grep ...`): prefer it to running the command again.
