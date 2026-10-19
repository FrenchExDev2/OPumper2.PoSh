BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'TestSupport.ps1')
    Import-Module (Join-Path $script:OP2TestRoot 'build/FrenchExDev.OPumper2.Build.psm1') -Force
}

Describe 'Engine build' {
    It 'lists the available runtimes in order, Auto preferring containers' {
        InModuleScope FrenchExDev.OPumper2.Build {
            Mock Get-Command { [pscustomobject]@{ Source = "/bin/$Name" } } -ParameterFilter { $Name -in @('docker','dotnet') }
            Mock Get-Command {} -ParameterFilter { $Name -eq 'podman' }
            (@(Resolve-OP2BuildRuntime) | ForEach-Object { "$($_.Kind)=$($_.Executable)" }) -join ',' | Should -BeExactly 'Docker=/bin/docker,Host=/bin/dotnet'
            @(Resolve-OP2BuildRuntime Podman).Count | Should -Be 0
            (Resolve-OP2BuildRuntime Host).Kind | Should -BeExactly 'Host'
        }
    }
    It 'composes a disposable container run: read-only mounts, sorted environment, no network unless asked, Docker as the user' {
        InModuleScope FrenchExDev.OPumper2.Build {
            $mounts = @(@{ Source = 'C:\p'; Target = '/src'; Writable = $false }, @{ Source = 'C:\p\.cache'; Target = '/src/.cache'; Writable = $true })
            $podman = New-OP2ContainerArgument -Kind Podman -Image 'img@sha256:1' -Mount $mounts -Environment @{ B = '2'; A = '1' } -Command @('dotnet', 'build') -User '1:1'
            ($podman -join ' ') | Should -BeExactly 'run --rm --workdir /src --network=none --volume C:\p:/src:ro --volume C:\p\.cache:/src/.cache --env A=1 --env B=2 img@sha256:1 dotnet build'
            $docker = New-OP2ContainerArgument -Kind Docker -Image 'img' -Network -Command @('dotnet') -User '1000:1000' -WorkingDirectory '/w'
            ($docker -join ' ') | Should -BeExactly 'run --rm --workdir /w --user 1000:1000 img dotnet'
            (New-OP2ContainerArgument -Kind Docker -Image 'img' -Command @('x')) -join ' ' | Should -BeExactly 'run --rm --workdir /src --network=none img x'
        }
    }
    It 'maps the calling user for Docker on Linux only' {
        InModuleScope FrenchExDev.OPumper2.Build {
            # id exists on Linux only: a stand-in lets Windows hosts run this case.
            function script:id { param([string]$Flag) }
            try {
                Mock id { $(if ($Flag -eq '-u') { '1000' } else { '1001' }) }
                Get-OP2BuildUser Docker $false | Should -BeExactly '1000:1001'
                Get-OP2BuildUser Docker $true | Should -BeNullOrEmpty
                Get-OP2BuildUser Podman $false | Should -BeNullOrEmpty
            } finally { Remove-Item function:script:id -ErrorAction SilentlyContinue }
        }
    }
    It 'turns host paths under the package root into container paths' {
        InModuleScope FrenchExDev.OPumper2.Build -Parameters @{ Directory = $TestDrive } {
            $root = Join-Path $Directory 'Pkg'
            ConvertTo-OP2ContainerPath (Join-Path $root 'engine/x.csproj') ($root + [IO.Path]::DirectorySeparatorChar) | Should -BeExactly '/src/engine/x.csproj'
            ConvertTo-OP2ContainerPath 'build' $root | Should -BeExactly 'build'
            # Windows paths ignore case.
            if ($IsWindows) { ConvertTo-OP2ContainerPath 'C:\Pkg\engine\x.csproj' 'c:\pkg\' | Should -BeExactly '/src/engine/x.csproj' }
        }
    }
    It 'pins an image by digest once, and pulls again only on request' {
        InModuleScope FrenchExDev.OPumper2.Build -Parameters @{ Directory = $TestDrive } {
            $lock = Join-Path $Directory 'images.lock.json'
            $runtime = [pscustomobject]@{ Kind = 'Podman'; Executable = 'podman' }
            $digest = 'mcr.microsoft.com/dotnet/sdk@sha256:' + ('a' * 64)
            Mock Invoke-OP2BuildProcess { [pscustomobject]@{ Outcome = 'Success'; FirstLine = $digest; Errors = @() } }
            Get-OP2LockedImage $runtime $lock 'sdk' 'mcr.microsoft.com/dotnet/sdk:10.0' | Should -BeExactly $digest
            (Get-Content $lock -Raw | ConvertFrom-Json).sdk.Source | Should -BeExactly 'mcr.microsoft.com/dotnet/sdk:10.0'
            Get-OP2LockedImage $runtime $lock 'sdk' 'ignored' | Should -BeExactly $digest
            Should -Invoke Invoke-OP2BuildProcess -Times 2 -Exactly
            Get-OP2LockedImage $runtime $lock 'sdk' 'mcr.microsoft.com/dotnet/sdk:10.0' -Update | Should -BeExactly $digest
            Should -Invoke Invoke-OP2BuildProcess -Times 4 -Exactly
            Mock Invoke-OP2BuildProcess { [pscustomobject]@{ Outcome = 'Success'; FirstLine = 'not-a-digest'; Errors = @() } }
            { Get-OP2LockedImage $runtime $lock 'other' 'x' } | Should -Throw '*Could not read the digest of x*'
            Mock Invoke-OP2BuildProcess { [pscustomobject]@{ Outcome = 'Failed'; FirstLine = $null; Errors = @('name resolution') } }
            { Get-OP2LockedImage $runtime $lock 'other' 'x' } | Should -Throw '*Could not pull x with Podman: name resolution*'
            Mock Invoke-OP2BuildProcess { if ($ArgumentList[0] -eq 'pull') { [pscustomobject]@{ Outcome = 'Success'; FirstLine = $null; Errors = @() } } else { [pscustomobject]@{ Outcome = 'Failed'; FirstLine = $digest; Errors = @() } } }
            { Get-OP2LockedImage $runtime $lock 'other' 'x' } | Should -Throw '*Could not read the digest*'
        }
    }
    It 'runs a process without pump, keeping only its errors on failure, its first line and its timeout' {
        InModuleScope FrenchExDev.OPumper2.Build -Parameters @{ Executable = $script:OP2TestExecutable } {
            Mock Get-Command {} -ParameterFilter { $Name -eq 'FrenchExDev.OPumper2.PoSh\Pump-Me' }
            $failed = Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', '"first"; "error CS1: broken"; [Console]::Error.WriteLine("access denied"); "fine"; exit 3') -Environment @{ OP2_BUILD = 'x' }
            "$($failed.Outcome)|$($failed.ExitCode)|$($failed.FirstLine)|$($failed.Errors -join ';')" | Should -BeExactly 'Failed|3|first|error CS1: broken;access denied'
            $ok = Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', '""; "  out  "; "0 Error(s)"; $env:OP2_BUILD') -Environment @{ OP2_BUILD = 'seen' }
            "$($ok.Outcome)|$($ok.FirstLine)|$(@($ok.Errors).Count)" | Should -BeExactly 'Success|out|0'
            $silent = Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', 'exit 0')
            $null -eq $silent.FirstLine | Should -BeTrue
            $slow = Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutSeconds 1
            $slow.Outcome | Should -BeExactly 'Timeout'
            # A failure that says error nowhere still explains itself: its last five lines come back.
            $quiet = Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', '1..7 | ForEach-Object { "step $_" }; exit 4')
            "$($quiet.Outcome)|$($quiet.Errors -join ',')" | Should -BeExactly 'Failed|step 3,step 4,step 5,step 6,step 7'
            $missing = Invoke-OP2BuildProcess 'op2-missing-build-tool' @()
            "$($missing.Outcome)|$([bool]$missing.Message)" | Should -BeExactly 'Failed|True'
        }
    }
    It 'keeps at most twenty error lines, takes the first executable found, and bounds its timeouts' {
        InModuleScope FrenchExDev.OPumper2.Build -Parameters @{ Executable = $script:OP2TestExecutable } {
            $script = '1..25 | ForEach-Object { "error $_" }; exit 1'
            $piped = Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', $script)
            "$(@($piped.Errors).Count)|$($piped.Errors[-1])" | Should -BeExactly '20|error 20'
            Mock Get-Command {} -ParameterFilter { $Name -eq 'FrenchExDev.OPumper2.PoSh\Pump-Me' }
            $direct = Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', $script)
            "$(@($direct.Errors).Count)|$($direct.Errors[-1])" | Should -BeExactly '20|error 20'
            Mock Get-Command { [pscustomobject]@{ Source = '/first/podman' }; [pscustomobject]@{ Source = '/second/podman' } } -ParameterFilter { $Name -eq 'podman' }
            (Resolve-OP2BuildRuntime Podman).Executable | Should -BeExactly '/first/podman'
            foreach ($timeout in @(0, 86401)) {
                { Invoke-OP2BuildProcess $Executable -TimeoutSeconds $timeout } | Should -Throw '*TimeoutSeconds*'
                { Invoke-OP2Dotnet ([pscustomobject]@{ Kind = 'Host' }) @('build') -TimeoutSeconds $timeout } | Should -Throw '*TimeoutSeconds*'
            }
            Mock Invoke-OP2BuildProcess { [pscustomobject]@{ Outcome = 'Success'; Timeout = $TimeoutSeconds } }
            "$((Invoke-OP2Dotnet ([pscustomobject]@{ Kind = 'Host'; Executable = 'dotnet' }) @('build') -TimeoutSeconds 1).Timeout)|$((Invoke-OP2Dotnet ([pscustomobject]@{ Kind = 'Host'; Executable = 'dotnet' }) @('build') -TimeoutSeconds 86400).Timeout)" | Should -BeExactly '1|86400'
        }
    }
    It 'stops the whole process tree of a run that times out' {
        InModuleScope FrenchExDev.OPumper2.Build -Parameters @{ Executable = $script:OP2TestExecutable; Marker = (Join-Path $TestDrive 'grandchild.pid') } {
            Mock Get-Command {} -ParameterFilter { $Name -eq 'FrenchExDev.OPumper2.PoSh\Pump-Me' }
            $child = "`$p = Start-Process -FilePath '$Executable' -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 60' -PassThru -NoNewWindow; Set-Content -LiteralPath '$Marker' `$p.Id; Start-Sleep -Seconds 60"
            (Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', $child) -TimeoutSeconds 6).Outcome | Should -BeExactly 'Timeout'
            $grandchild = Get-Process -Id ([int](Get-Content -LiteralPath $Marker)) -ErrorAction SilentlyContinue
            if ($grandchild) { $grandchild.WaitForExit(10000) | Should -BeTrue }
        }
    }
    It 'runs a process through pump when the engine is loaded, with the same bounded result' {
        InModuleScope FrenchExDev.OPumper2.Build -Parameters @{ Executable = $script:OP2TestExecutable } {
            $failed = Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', '""; "first"; "error CS1: broken"; exit 3')
            "$($failed.Outcome)|$($failed.ExitCode)|$($failed.FirstLine)|$($failed.Errors -join ';')" | Should -BeExactly 'Failed|3|first|error CS1: broken'
            $ok = Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', '"0 Error(s)"')
            "$($ok.Outcome)|$($ok.FirstLine)|$(@($ok.Errors).Count)" | Should -BeExactly 'Success|0 Error(s)|0'
            $quiet = Invoke-OP2BuildProcess $Executable @('-NoProfile', '-Command', '1..7 | ForEach-Object { "step $_" }; ""; exit 4')
            "$($quiet.Outcome)|$($quiet.Errors -join ',')" | Should -BeExactly 'Failed|step 3,step 4,step 5,step 6,step 7'
        }
    }
    It 'runs dotnet on the host, or in the container with the package mounted, its cache writable and paths translated' {
        InModuleScope FrenchExDev.OPumper2.Build -Parameters @{ Directory = $TestDrive } {
            $seen = [Collections.Generic.List[object]]::new()
            Mock Invoke-OP2BuildProcess { $seen.Add(@{ File = $FilePath; Arguments = $ArgumentList; Environment = $Environment; Directory = $WorkingDirectory }); [pscustomobject]@{ Outcome = 'Success' } }
            [void](Invoke-OP2Dotnet ([pscustomobject]@{ Kind = 'Host'; Executable = 'dotnet' }) @('build', 'x.csproj') -Root $Directory)
            "$($seen[0].File)|$($seen[0].Arguments -join ' ')|$($seen[0].Environment.DOTNET_CLI_UI_LANGUAGE)|$($seen[0].Directory -eq $Directory)" | Should -BeExactly 'dotnet|build x.csproj|en-US|True'
            $output = Join-Path $Directory 'test/Artifacts/run'
            [void](Invoke-OP2Dotnet ([pscustomobject]@{ Kind = 'Podman'; Executable = 'podman' }) @('test', (Join-Path $output 'r')) -Image 'sdk@sha256:1' -Network -Root $Directory -Writable @($output))
            $arguments = $seen[1].Arguments -join ' '
            $seen[1].File | Should -BeExactly 'podman'
            $arguments | Should -Match ([regex]::Escape("--volume ${Directory}:/src:ro"))
            $arguments | Should -Match ([regex]::Escape("--volume $(Join-Path $Directory '.cache/container'):/src/.cache "))
            $arguments | Should -Match ([regex]::Escape("--volume ${output}:/src/test/Artifacts/run "))
            $arguments | Should -Match ([regex]::Escape('--env NUGET_PACKAGES=/src/.cache/nuget'))
            $arguments | Should -Match ([regex]::Escape('sdk@sha256:1 dotnet test /src/test/Artifacts/run/r'))
            $arguments | Should -Not -Match 'network=none'
            Test-Path -LiteralPath (Join-Path $Directory '.cache/container/nuget') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Directory '.cache/container/home') | Should -BeTrue
            $arguments | Should -Match ([regex]::Escape('--env DOTNET_CLI_HOME=/src/.cache/home'))
        }
    }
    It 'resolves a container target without ever falling back to the host, and runs dotnet in a folder of the root' {
        InModuleScope FrenchExDev.OPumper2.Build -Parameters @{ Directory = $TestDrive } {
            Mock Resolve-OP2BuildRuntime { [pscustomobject]@{ Kind = 'Docker'; Executable = 'docker' }; [pscustomobject]@{ Kind = 'Host'; Executable = 'dotnet' } }
            Mock Get-OP2LockedImage { throw 'offline' }
            $offline = Resolve-OP2BuildTarget Container -Root $Directory
            "$($null -eq $offline.Runtime)|$($offline.Reason)|$($offline.Skipped[0].Runtime)" | Should -BeExactly 'True|ImageUnavailable|Docker'
            Mock Get-OP2LockedImage { 'sdk@sha256:2' }
            $target = Resolve-OP2BuildTarget Container -Root $Directory
            "$($target.Runtime.Kind)|$($target.Image)|$($target.Skipped.Count)|$($null -eq $target.Reason)" | Should -BeExactly 'Docker|sdk@sha256:2|0|True'
            Mock Resolve-OP2BuildRuntime { [pscustomobject]@{ Kind = 'Host'; Executable = 'dotnet' } }
            (Resolve-OP2BuildTarget Container -Root $Directory).Reason | Should -BeExactly 'ContainerRuntimeUnavailable'
            $seen = [Collections.Generic.List[object]]::new()
            Mock Invoke-OP2BuildProcess { $seen.Add(@{ Arguments = $ArgumentList; Directory = $WorkingDirectory }); [pscustomobject]@{ Outcome = 'Success' } }
            [void](Invoke-OP2Dotnet ([pscustomobject]@{ Kind = 'Host'; Executable = 'dotnet' }) @('tool', 'restore') -Root $Directory -WorkingDirectory 'engine')
            $seen[0].Directory | Should -BeExactly (Join-Path $Directory 'engine')
            [void](Invoke-OP2Dotnet ([pscustomobject]@{ Kind = 'Podman'; Executable = 'podman' }) @('tool', 'restore') -Image 'sdk' -Root $Directory -WorkingDirectory '\engine\')
            ($seen[1].Arguments -join ' ') | Should -Match '^run --rm --workdir /src/engine '
        }
    }
    It 'builds with the first runtime that can, reporting the ones passed over, and names a failing step' {
        InModuleScope FrenchExDev.OPumper2.Build -Parameters @{ Directory = $TestDrive } {
            Mock Resolve-OP2BuildRuntime {}
            (Invoke-OPumper2EngineBuild -Root $Directory).Reason | Should -BeExactly 'ContainerRuntimeUnavailable'
            (Invoke-OPumper2EngineBuild -Runtime Host -Root $Directory).Reason | Should -BeExactly 'DotnetUnavailable'
            Mock Resolve-OP2BuildRuntime { [pscustomobject]@{ Kind = 'Podman'; Executable = 'podman' } }
            Mock Get-OP2LockedImage { throw 'no registry' }
            $none = Invoke-OPumper2EngineBuild -Root $Directory
            "$($none.Reason)|$($none.Skipped[0].Runtime)|$($none.Skipped[0].Message)" | Should -BeExactly 'ImageUnavailable|Podman|no registry'
            Mock Resolve-OP2BuildRuntime { [pscustomobject]@{ Kind = 'Podman'; Executable = 'podman' }; [pscustomobject]@{ Kind = 'Host'; Executable = 'dotnet' } }
            $calls = [Collections.Generic.List[string]]::new()
            Mock Invoke-OP2Dotnet { $calls.Add("$($Runtime.Kind):$($ArgumentList[0]):$([bool]$Network):$(@($Writable | ForEach-Object { Split-Path $_ -Leaf }) -join '+')"); [pscustomobject]@{ Outcome = 'Success'; ExitCode = 0; Errors = @() } }
            $built = Invoke-OPumper2EngineBuild -Project Engine, Dependencies -Test -Root $Directory
            "$($built.Outcome)|$($built.Runtime)|$($built.Skipped.Count)|$($built.Steps.Count)" | Should -BeExactly 'Success|Host|1|6'
            $built.EngineAssembly | Should -BeExactly (Join-Path $Directory '.cache/engine/bin/FrenchExDev.OPumper2.Engine/FrenchExDev.OPumper2.Engine.dll')
            # Only the runtime dependency build writes outside .cache: into resources/runtime.
            ($calls -join ',') | Should -BeExactly 'Host:restore:True:,Host:build:False:,Host:restore:True:,Host:build:False:runtime,Host:restore:True:,Host:test:False:'
            Mock Get-OP2LockedImage { 'sdk@sha256:1' }
            Mock Invoke-OP2Dotnet { [pscustomobject]@{ Outcome = $(if ($ArgumentList[0] -eq 'build') { 'Failed' } else { 'Success' }); ExitCode = 1; Errors = @('CS1') } }
            $failed = Invoke-OPumper2EngineBuild -Root $Directory
            "$($failed.Outcome)|$($failed.Runtime)|$($failed.Image)|$($failed.Reason)|$($failed.Steps[-1].Errors)" | Should -BeExactly 'Failed|Podman|sdk@sha256:1|Engine.BuildFailed|CS1'
        }
    }
}
