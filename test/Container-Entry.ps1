#requires -Version 7.6
[CmdletBinding()]
param([ValidateSet('Engine','Git','Dotnet','Node','Python','Rust','Go','Make','Jvm','Containers','Kubernetes','Systemd','GitHub','Terraform','Search','Agent','All')][string]$Package = 'All', [switch]$Mutation, [string]$ExpectedRuntime,
    [ValidateRange(0,64)][Nullable[int]]$Workers)
$engine = Split-Path $PSScriptRoot
$parent = Split-Path $engine
$runtime = Join-Path $engine 'resources/runtime'
# The runtime identifier distinguishes musl (Alpine: linux-musl-x64) from glibc builds of the native library.
$identifier = [Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier
Copy-Item -LiteralPath (Join-Path $runtime "runtimes/$identifier/native/libe_sqlite3.so") -Destination (Join-Path $runtime 'libe_sqlite3.so') -Force
[void][IO.Directory]::CreateDirectory('/artifacts')
$exitCode = 1
try {
    if ($ExpectedRuntime -and !$PSVersionTable.PSVersion.ToString().StartsWith($ExpectedRuntime)) { throw 'Container PowerShell version does not match the requested runtime.' }
    $options = @{}
    if ($null -ne $Workers) { $options.Workers = $Workers }
    & (Join-Path $PSScriptRoot 'Invoke-Tests.ps1') -Package $Package -Suite All -Analyze -Mutation:$Mutation @options
    $exitCode = $LASTEXITCODE
} catch {
    @{Outcome='Failed';Error=@{Type=$_.Exception.GetType().FullName;Message=$_.Exception.Message};Runtime=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json -Compress
} finally {
    . (Join-Path $PSScriptRoot 'ToolSupport.ps1')
    foreach ($name in (Get-OP2TestPackage).Values) {
        $reports = Join-Path $parent "$name/test/Artifacts"
        if (Test-Path -LiteralPath $reports) { Copy-Item -LiteralPath $reports -Destination (Join-Path '/artifacts' $name) -Recurse -Force }
    }
}
exit $exitCode
