#requires -Version 7.0

<#
.SYNOPSIS
Runs a complete trusted C# console program or genuine xUnit v3 tests.
.DESCRIPTION
Accepts a schemaVersion 1 JSON manifest, or direct options normalized to the
same manifest. Requires an installed .NET 10+ SDK and the requested runtime.
Executes code and package build assets with your permissions; this is not a sandbox.
.PARAMETER ManifestJson
Canonical JSON manifest with schemaVersion, mode, framework, source and optional
dependsOn, sdk and frameworkReferences fields. Exclusive with direct options.
.PARAMETER Mode
console (default) or test.
.PARAMETER Framework
Target framework; defaults to net11.0 for direct use.
.PARAMETER DependsOn
Explicit PackageId@ExactVersion pins. No floating versions or discovery.
.PARAMETER Source
Complete C# source text, exclusive with File and Clipboard.
.PARAMETER File
UTF-8 C# source file, exclusive with Source and Clipboard.
.PARAMETER Clipboard
Read complete source from the clipboard. Also the default if no source is given.
.EXAMPLE
./csrun.ps1 -Source 'System.Console.WriteLine("hello");'
.EXAMPLE
./csrun.ps1 -ManifestJson (Get-Content ./samples/datespan.json -Raw)
.EXAMPLE
./csrun.ps1 -Mode test -File ./tests/fixtures/OutputLinesTest.cs -DependsOn Codebelt.Extensions.Xunit@13.0.0,xunit.v3@4.0.3
.EXAMPLE
./csrun.ps1 -Clipboard -Framework net11.0
#>
[CmdletBinding()]
param(
    [string] $ManifestJson,
    [string] $Mode = 'console',
    [string] $Framework = 'net11.0',
    [string[]] $DependsOn = @(),
    [string] $Source,
    [string] $File,
    [switch] $Clipboard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Native failures are propagated explicitly, including under caller profiles.
$PSNativeCommandUseErrorActionPreference = $false

function Get-PackagePins($Specs) {
    $pins = [ordered]@{}
    foreach ($spec in $Specs) {
        if ($spec -isnot [string] -or $spec -cnotmatch '^(?<id>[A-Za-z0-9_][A-Za-z0-9_.-]{0,99})@(?<version>[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)$') {
            throw "Invalid package pin '$spec'; use PackageId@ExactVersion (for example xunit.v3@4.0.3)."
        }
        $id = $Matches.id
        $version = $Matches.version
        if ($pins.Contains($id) -and $pins[$id] -cne $version) { throw "Conflicting package versions for '$id'." }
        $pins[$id] = $version
    }
    return ,$pins
}

function Get-ValidatedManifest($InputManifest) {
    if ($InputManifest -isnot [System.Collections.IDictionary]) { throw 'Manifest must be a JSON object.' }
    $allowed = @('schemaVersion', 'mode', 'framework', 'source', 'dependsOn', 'sdk', 'frameworkReferences')
    foreach ($key in $InputManifest.Keys) {
        if ($key -cnotin $allowed) { throw "Unknown manifest field '$key'." }
    }
    foreach ($key in @('schemaVersion', 'mode', 'framework', 'source')) {
        if (-not $InputManifest.Contains($key)) { throw "Missing required manifest field '$key'." }
    }
    if (($InputManifest.schemaVersion -isnot [long] -and $InputManifest.schemaVersion -isnot [int]) -or $InputManifest.schemaVersion -ne 1) {
        throw 'Unsupported schemaVersion; expected integer 1.'
    }
    if ($InputManifest.mode -isnot [string] -or $InputManifest.mode -notin @('console', 'test')) { throw 'Unsupported mode; use console or test.' }
    if ($InputManifest.framework -isnot [string] -or $InputManifest.framework -cnotmatch '^net(?<major>[5-9]|[1-9][0-9]+)\.0(?:-(?:windows(?:[0-9]+(?:\.[0-9]+){0,3})?|linux|macos(?:[0-9]+(?:\.[0-9]+){0,2})?))?$') {
        throw 'Invalid framework; use a target framework such as net11.0, not a runtime identifier such as win-x64.'
    }
    if ($InputManifest.source -isnot [string] -or [string]::IsNullOrWhiteSpace($InputManifest.source)) { throw 'source must be a nonempty complete C# program or test source.' }
    $sdk = 'Microsoft.NET.Sdk'
    if ($InputManifest.Contains('sdk')) {
        if ($InputManifest.sdk -cnotin @('Microsoft.NET.Sdk', 'Microsoft.NET.Sdk.Web')) { throw 'Unsupported sdk; use Microsoft.NET.Sdk or Microsoft.NET.Sdk.Web.' }
        $sdk = $InputManifest.sdk
    }
    $specs = @()
    if ($InputManifest.Contains('dependsOn')) {
        if ($InputManifest.dependsOn -isnot [array]) { throw 'dependsOn must be an array of package pins.' }
        $specs = $InputManifest.dependsOn
    }
    $pins = Get-PackagePins $specs
    $refs = @()
    if ($InputManifest.Contains('frameworkReferences')) {
        if ($InputManifest.frameworkReferences -isnot [array]) { throw 'frameworkReferences must be an array.' }
        foreach ($ref in $InputManifest.frameworkReferences) {
            if ($ref -isnot [string] -or $ref -cnotmatch '^[A-Za-z][A-Za-z0-9_.]*$') { throw 'Invalid frameworkReferences entry.' }
        }
        $refs = @($InputManifest.frameworkReferences | Select-Object -Unique)
    }
    $executionMode = $InputManifest.mode.ToLowerInvariant()
    if ($executionMode -eq 'test') {
        foreach ($id in @($pins.Keys)) {
            if ($id -like 'xunit*' -and $id -notin @('xunit.v3', 'xunit.analyzers')) {
                throw "Incompatible test infrastructure package '$id'; use xunit.v3@4.0.3."
            }
        }
        if ($pins.Contains('xunit.v3')) {
            # The supported compatibility band uses the same MTP v2 integration.
            if ($pins['xunit.v3'] -notmatch '^4\.0\.(\d+)$' -or [long]$Matches[1] -lt 3) { throw 'Incompatible xunit.v3 pin; supported baseline is 4.0.3 (stable 4.0 patch versions >= 3).'}
        } else { $pins['xunit.v3'] = '4.0.3' }
    } elseif ($refs.Count -gt 0 -and ($sdk -cne 'Microsoft.NET.Sdk.Web' -or @($refs | Where-Object { $_ -cne 'Microsoft.AspNetCore.App' }).Count -gt 0)) {
        throw 'Console frameworkReferences require sdk Microsoft.NET.Sdk.Web and Microsoft.AspNetCore.App; use test mode for other explicit framework references.'
    }
    return @{ Mode = $executionMode; Framework = $InputManifest.framework; Source = $InputManifest.source; Sdk = $sdk; Pins = $pins; References = $refs }
}

function Get-ConsoleSource($Manifest) {
    $directives = [ordered]@{ 'property TargetFramework' = $Manifest.Framework; 'sdk' = $Manifest.Sdk }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $Manifest.Pins.Keys) { $directives["package $id"] = $Manifest.Pins[$id] }
    # Inspect only the directive preamble, never C# declarations or method bodies.
    # Original source is appended byte-for-character, including existing directives.
    $inBlockComment = $false
    foreach ($line in ($Manifest.Source -split '\r\n|\n|\r')) {
        $text = $line.Trim()
        # Skip leading comments only; do not scan strings or the C# program body.
        while ($text.Length -gt 0) {
            if ($inBlockComment) {
                $end = $text.IndexOf('*/', [StringComparison]::Ordinal)
                if ($end -lt 0) { $text = ''; break }
                $text = $text.Substring($end + 2).TrimStart(); $inBlockComment = $false
            } elseif ($text.StartsWith('/*')) { $inBlockComment = $true; $text = $text.Substring(2) }
            else { break }
        }
        if ($text.Length -eq 0 -or $text.StartsWith('//')) { continue }
        # C# preprocessor directives such as #nullable do not end the SDK's
        # directive preamble. Leave them untouched, but validate following #: lines.
        if ($text.StartsWith('#') -and -not $text.StartsWith('#:')) { continue }
        if (-not $text.StartsWith('#:')) { break }
        $key = $null
        $value = $null
        if ($text -cmatch '^#:property\s+TargetFramework\s*=\s*(\S+)\s*$') { $key = 'property TargetFramework'; $value = $Matches[1] }
        elseif ($text -cmatch '^#:sdk\s+(\S+)\s*$') { $key = 'sdk'; $value = $Matches[1] }
        elseif ($text -cmatch '^#:package\s+(\S+)\s*$') {
            $pin = Get-PackagePins @($Matches[1])
            $id = @($pin.Keys)[0]; $key = "package $id"; $value = $pin[$id]
        } else { throw "Unsupported source directive '$text'; put build configuration in the manifest." }
        if (-not $directives.Contains($key) -or $directives[$key] -cne $value) { throw "Source directive conflicts with manifest: $text" }
        if ($seen.Contains($key)) { throw "Duplicate source directive '$text'; the SDK requires one occurrence per setting." }
        # A matching directive in the original source supplies this setting.
        $null = $seen.Add($key)
    }
    $preamble = foreach ($key in $directives.Keys) {
        if ($seen.Contains($key)) { continue }
        if ($key -eq 'sdk') { "#:sdk $($directives[$key])" }
        elseif ($key.StartsWith('package ')) { "#:$key@$($directives[$key])" }
        else { "#:$key=$($directives[$key])" }
    }
    # NuGet must not substitute an approximate match for an unavailable pin.
    return ($preamble -join "`n") + "`n#:property WarningsAsErrors=NU1603;NU1605`n" + $Manifest.Source
}

function Write-TestProject($Manifest, [string] $Directory) {
    $project = Join-Path $Directory 'Sample.csproj'
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($project, $settings)
    try {
        $writer.WriteStartElement('Project'); $writer.WriteAttributeString('Sdk', $Manifest.Sdk)
        $writer.WriteStartElement('PropertyGroup')
        foreach ($pair in @{ OutputType = 'Exe'; TargetFramework = $Manifest.Framework; UseMicrosoftTestingPlatformRunner = 'true'; ImplicitUsings = 'enable'; Nullable = 'enable' }.GetEnumerator()) {
            $writer.WriteElementString($pair.Key, $pair.Value)
        }
        $writer.WriteEndElement()
        $writer.WriteStartElement('ItemGroup')
        foreach ($id in $Manifest.Pins.Keys) {
            $writer.WriteStartElement('PackageReference'); $writer.WriteAttributeString('Include', $id)
            # NuGet bracket syntax enforces an exact version rather than a lower bound.
            $writer.WriteAttributeString('Version', "[$($Manifest.Pins[$id])]"); $writer.WriteEndElement()
        }
        foreach ($ref in $Manifest.References) {
            if ($Manifest.Sdk -eq 'Microsoft.NET.Sdk.Web' -and $ref -eq 'Microsoft.AspNetCore.App') { continue }
            $writer.WriteStartElement('FrameworkReference'); $writer.WriteAttributeString('Include', $ref); $writer.WriteEndElement()
        }
        $writer.WriteEndElement(); $writer.WriteEndElement()
    } finally { $writer.Dispose() }
    [System.IO.File]::WriteAllText((Join-Path $Directory 'Sample.cs'), $Manifest.Source, [System.Text.UTF8Encoding]::new($false))
    return $project
}

$temporaryDirectory = $null
$exitCode = 1
try {
    if ($PSBoundParameters.ContainsKey('ManifestJson')) {
        if (@($PSBoundParameters.Keys | Where-Object { $_ -in @('Mode', 'Framework', 'DependsOn', 'Source', 'File', 'Clipboard') }).Count -gt 0) { throw 'ManifestJson is mutually exclusive with direct input/configuration arguments.' }
        try { $inputManifest = ConvertFrom-Json -InputObject $ManifestJson -AsHashtable -ErrorAction Stop }
        catch { throw "Invalid manifest JSON: $($_.Exception.Message)" }
    } else {
        $sourceCount = @($PSBoundParameters.Keys | Where-Object { $_ -in @('Source', 'File', 'Clipboard') }).Count
        if ($sourceCount -gt 1) { throw 'Source, File and Clipboard are mutually exclusive.' }
        if ($PSBoundParameters.ContainsKey('File')) { $Source = Get-Content -LiteralPath $File -Raw -Encoding utf8 }
        elseif (-not $PSBoundParameters.ContainsKey('Source')) {
            if (-not (Get-Command Get-Clipboard -ErrorAction SilentlyContinue)) { throw 'Clipboard unavailable; supply Source or File.' }
            try { $Source = Get-Clipboard -Raw -ErrorAction Stop }
            catch { throw 'Clipboard unavailable; supply Source or File.' }
        }
        $inputManifest = @{ schemaVersion = 1; mode = $Mode; framework = $Framework; dependsOn = $DependsOn; source = $Source }
    }
    $manifest = Get-ValidatedManifest $inputManifest
    $consoleSource = $null
    if ($manifest.Mode -eq 'console') { $consoleSource = Get-ConsoleSource $manifest }
    $dotnet = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $dotnet) { throw 'Missing .NET SDK; install a compatible .NET 10+ SDK and the requested runtime.' }
    $sdkVersion = & $dotnet.Source --version
    if ($LASTEXITCODE -ne 0 -or $sdkVersion -notmatch '^(\d+)\.' -or [int]$Matches[1] -lt 10) { throw 'No compatible .NET 10+ SDK selected. Check installed SDKs and the current directory global.json.' }
    $dependencies = @($manifest.Pins.Keys | ForEach-Object { "$_@$($manifest.Pins[$_])" })
    Write-Host "csrun: $($manifest.Mode) | $($manifest.Framework) | dependencies: $($dependencies -join ', ')"
    if ($manifest.Mode -eq 'console') {
        $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        if (@(Get-ChildItem -LiteralPath (Get-Location).Path -File -Filter '*.*proj').Count -gt 0) {
            # SDK 11 selects a current-directory project before considering '-'.
            # --file forces native file-based execution without changing program cwd.
            $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('csrun-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $temporaryDirectory
            $entryFile = Join-Path $temporaryDirectory 'Sample.cs'
            [System.IO.File]::WriteAllText($entryFile, $consoleSource, [System.Text.UTF8Encoding]::new($false))
            & $dotnet.Source run --file $entryFile --no-launch-profile
        } else {
            $consoleSource | & $dotnet.Source run - --no-launch-profile
        }
        $exitCode = $LASTEXITCODE
    } else {
        $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('csrun-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $temporaryDirectory
        $project = Write-TestProject $manifest $temporaryDirectory
        & $dotnet.Source run --project $project --no-launch-profile -- --show-live-output on --progress off --no-banner
        $exitCode = $LASTEXITCODE
    }
} catch {
    [Console]::Error.WriteLine("csrun: $($_.Exception.Message)")
    $exitCode = 1
} finally {
    if ($null -ne $temporaryDirectory -and (Test-Path -LiteralPath $temporaryDirectory)) {
        try {
            $resolvedDirectory = [System.IO.Path]::GetFullPath($temporaryDirectory)
            $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            if ([System.IO.Path]::GetDirectoryName($resolvedDirectory) -cne $tempRoot -or [System.IO.Path]::GetFileName($resolvedDirectory) -cnotmatch '^csrun-[a-f0-9]{32}$') { throw 'Unsafe temporary artifact cleanup path.' }
            Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
        }
        catch { [Console]::Error.WriteLine("csrun: could not clean temporary artifacts '$temporaryDirectory': $($_.Exception.Message)"); if ($exitCode -eq 0) { $exitCode = 1 } }
    }
}
exit $exitCode
