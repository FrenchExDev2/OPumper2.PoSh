#requires -Version 7.6
# Runs dotnet with English messages and UTF-8 console output: tools such as Stryker.NET write to the console code page,
# which the strict UTF-8 decoder of pump rejects on a localized Windows. The arguments reach dotnet unchanged.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:DOTNET_CLI_UI_LANGUAGE = 'en-US'
& dotnet @args
exit $LASTEXITCODE
