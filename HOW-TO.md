# Examples

Import `FrenchExDev.OPumper2.PoSh.psd1` once.

See [the command-line example](examples/CommandLine.ps1) for `pump` with native options and the delivery of a failed call: exit code, masked excerpt of each stream, and the contract's `Data`.

See [the direct synthetic example](examples/Direct.ps1) for separate callbacks, local state and a final projection through `Pump-Me -ArgumentList`.

See [the obfuscation example](examples/Obfuscation.ps1) for pattern and script middlewares masking delivered output.

See [the local object example](examples/LocalObject.ps1) for a script that branches on its result. Keep the `-AsObject` value in a variable, decide on its fields, and deliver only what you chose:

```powershell
$result = pump -AsObject -OnRecord { param($record, $state) ... } <command>
if ($result.Outcome -ne 'Success') {
    # The capture answers what the contract did not foresee, inside this script only.
    $lines = ($result.Capture.Stdout -split "`r?`n").Count
    New-OPumper2Result -Completion $result -Data @{ Errors = $result.Data.Errors; Lines = $lines } | Out-OPumper2
    return
}
$result.Data.Summary                # one chosen field
```

Never write the object itself to the output (`$result`, `$result | Format-List`, `Write-Output $result`): it holds the complete `Capture`, the domain `Data`, the `Presentation` scriptblocks and methods, unbounded and unmasked. `Out-OPumper2` (`-AsJson`/`-AsYaml`, `-MaxItems`, `-MaxOutputBytes`, `-ExcerptLines`) delivers values ending with a completion as pump would have, recall id and excerpt included; it wraps any other values in the `Data` of a successful result. When a contract writes records, the completion is the last value: `@($result)[-1]`. Several pumped steps that make one answer belong in `Invoke-OPumper2Task { ... }`, which delivers one result.

See [the Git consumer](../FrenchExDev.OPumper2.Git.PoSh/README.md) for a domain module and the same observation invoked directly or through `pump git status`, and [the dotnet consumer](../FrenchExDev.OPumper2.Dotnet.PoSh/README.md) for a route returning a Result with its own delivered projection. [The filters](doc/FILTERS.md) show routes declared as data in ecosystem catalogue modules, [the agent module](../FrenchExDev.OPumper2.Utility.Agent.PoSh/README.md) loading them all, and [recall](doc/RECALL.md) reading a delivered output back.

Read [the contract](CONTRACT.md) when changing callbacks or output modes, [the registry](doc/REGISTRY.md) when registering reusable routes, and [quality](doc/QUALITY.md) when running validation.
