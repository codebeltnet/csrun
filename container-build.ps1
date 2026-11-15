#requires -Version 7.0
# Build-time only. This file is removed before the image is used.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
try {
    $rid = switch ($env:TARGETARCH) { 'amd64' { 'linux-x64' } 'arm64' { 'linux-arm64' } default { throw "Unsupported architecture '$env:TARGETARCH'." } }
    foreach ($sdk in (ConvertFrom-Json -InputObject $env:SDK_ARTIFACTS_JSON)) {
        if (Test-Path "/usr/share/dotnet/sdk/$($sdk.version)") { throw "SDK $($sdk.version) is already installed in the base image." }
        $files = @($sdk.files | Where-Object { $_.rid -ceq $rid -and $_.url.EndsWith('.tar.gz') })
        if ($files.Count -ne 1) { throw "No unique SDK $($sdk.version) archive for $rid." }
        $file = $files[0]
        if ($file.url -notmatch '^https://(builds\.dotnet\.microsoft\.com|download\.visualstudio\.microsoft\.com)/' -or $file.hash -notmatch '^[a-fA-F0-9]{128}$') { throw 'Expected an official SDK URL and SHA-512 hash.' }
        $archive = '/tmp/csrun-sdk.tar.gz'
        Invoke-WebRequest -Uri $file.url -OutFile $archive
        if ((Get-FileHash $archive -Algorithm SHA512).Hash -ine $file.hash) { throw "SDK $($sdk.version) checksum mismatch." }
        # Keep the newest host and shared files from the base. Versioned SDKs,
        # targeting packs and both NETCore/ASP.NET runtimes install side by side.
        & tar --extract --gzip --file $archive --directory /usr/share/dotnet --skip-old-files --no-same-owner
        if ($LASTEXITCODE -ne 0) { throw 'SDK archive extraction failed.' }
        Remove-Item -LiteralPath $archive
    }
    & dotnet --list-sdks
    if ($LASTEXITCODE -ne 0) { throw 'SDK inventory failed.' }
    & dotnet --list-runtimes
    if ($LASTEXITCODE -ne 0) { throw 'Runtime inventory failed.' }
} catch { [Console]::Error.WriteLine($_); exit 1 }
