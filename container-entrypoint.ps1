#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    $manifest = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($manifest)) { throw 'Expected a UTF-8 JSON manifest on stdin; use docker run --rm -i.' }
    # ExternalScriptInfo invocation exits PowerShell. A scriptblock returns here
    # and exposes the engine's status, including MTP's nonzero test results.
    & ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'csrun.ps1')))) -ManifestJson $manifest
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine("csrun container: $($_.Exception.Message)")
    exit 1
}
