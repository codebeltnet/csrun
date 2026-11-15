#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runner = (Resolve-Path "$PSScriptRoot/../csrun.ps1").Path
$pwsh = (Get-Process -Id $PID).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('csrun-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$passed = 0
$failed = 0

function Invoke-Runner {
    param([hashtable] $Arguments, [switch] $ScriptBlock, [hashtable] $Environment = @{}, [string] $WorkingDirectory = $root, [string] $ClipboardText = '', [switch] $ClipboardFailure)
    $payload = @{ path = $runner; arguments = $Arguments; scriptblock = [bool]$ScriptBlock; clipboardText = $ClipboardText; clipboardFailure = [bool]$ClipboardFailure } | ConvertTo-Json -Depth 12 -Compress
    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $command = @'
$data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json -AsHashtable
$parameters = $data.arguments
# Substitute only the clipboard IO seam; never mutate the user's clipboard.
if ($data.clipboardText) { function Get-Clipboard { param([switch] $Raw) $data.clipboardText } }
if ($data.clipboardFailure) { function Get-Clipboard { param([switch] $Raw) throw 'Clipboard unavailable in this test host.' } }
if ($data.scriptblock) {
    & ([scriptblock]::Create([IO.File]::ReadAllText($data.path))) @parameters
} else {
    & $data.path @parameters
}
exit $LASTEXITCODE
'@.Replace('__PAYLOAD__', $encodedPayload)
    $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) { $start.ArgumentList.Add($arg) }
    $start.Environment['DOTNET_NOLOGO'] = '1'
    $start.Environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
    $start.Environment['TESTINGPLATFORM_TELEMETRY_OPTOUT'] = '1'
    foreach ($tempVariable in @('TEMP', 'TMP', 'TMPDIR')) { $start.Environment[$tempVariable] = $root }
    foreach ($key in $Environment.Keys) { $start.Environment[$key] = $Environment[$key] }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) { $process.Kill($true); throw 'Runner timed out after 180 seconds.' }
        return @{ Code = $process.ExitCode; Out = $stdout.GetAwaiter().GetResult(); Err = $stderr.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}
function New-Manifest([string] $Source = 'System.Console.WriteLine("hello");', [string] $Mode = 'console', [string[]] $Pins = @()) {
    return @{ schemaVersion = 1; mode = $Mode; framework = 'net11.0'; source = $Source; dependsOn = $Pins }
}
function Invoke-Manifest([hashtable] $Manifest, [switch] $ScriptBlock) {
    Invoke-Runner -Arguments @{ ManifestJson = ($Manifest | ConvertTo-Json -Depth 10 -Compress) } -ScriptBlock:$ScriptBlock
}
function Assert-Result($Result, [int] $Code = 0, [string] $Pattern = '') {
    $all = $Result.Out + "`n" + $Result.Err
    if ($Result.Code -ne $Code -or ($Pattern -and $all -notmatch $Pattern)) {
        throw "Expected exit $Code and /$Pattern/, got exit $($Result.Code):`n$all"
    }
}
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name`n$_" }
}
try {
    Test-Case 'inline console and no user project' {
        Assert-Result (Invoke-Manifest (New-Manifest)) 0 '(?m)^hello\r?$'
        if (@(Get-ChildItem $root -Recurse -Filter *.csproj).Count) { throw 'Console created a user project.' }
    }
    Test-Case 'exact DateSpan example and output' {
        $manifest = Get-Content "$PSScriptRoot/../samples/datespan.json" -Raw | ConvertFrom-Json -AsHashtable
        if ($manifest.source -cne (Get-Content "$PSScriptRoot/fixtures/DateSpan.cs" -Raw)) { throw 'DateSpan manifest differs from original fixture.' }
        Assert-Result (Invoke-Manifest $manifest) 0 '(?s)0 years\r?\n9 months\r?\n40 weeks\r?\n273 days\r?\n6552 hours\r?\n393,120 minutes\r?\n23,587,200 seconds'
    }
    Test-Case 'unchanged Codebelt xUnit sample discovers one passing test and displays output' {
        $manifest = Get-Content "$PSScriptRoot/../samples/output-lines.json" -Raw | ConvertFrom-Json -AsHashtable
        if ($manifest.source -cne (Get-Content "$PSScriptRoot/fixtures/OutputLinesTest.cs" -Raw)) { throw 'Test source differs from original fixture.' }
        $result = Invoke-Manifest $manifest
        Assert-Result $result 0 '(?s)total: 1.*failed: 0.*succeeded: 1.*skipped: 0'
        foreach ($line in @('started', '2', 'finished')) { if ($result.Out -notmatch "(?m)^OUTPUT: .*\] $line\r?$") { throw "Missing live output: $line" } }
    }
    Test-Case 'assertion failure retains MTP exit 2 and diagnostic' {
        Assert-Result (Invoke-Manifest (New-Manifest 'using Xunit; public class Tests { [Fact] public void Fails() { Assert.Equal(1, 2); } }' test)) 2 'Assert.Equal\(\) Failure'
    }
    Test-Case 'zero discovered tests fails with native MTP exit 8' {
        Assert-Result (Invoke-Manifest (New-Manifest 'public class NoTests { }' test)) 8 'total: 0'
    }
    Test-Case 'real async theory, fixture lifecycle, injection and skips' {
        $source = @'
using System;
using System.Threading.Tasks;
using Xunit;
public class Fixture : IDisposable { public int Value = 42; public void Dispose() { Console.WriteLine("fixture-disposed"); } }
public class Tests : IClassFixture<Fixture> {
    private readonly Fixture fixture;
    private readonly ITestOutputHelper output;
    public Tests(Fixture fixture, ITestOutputHelper output) { this.fixture = fixture; this.output = output; }
    [Theory] [InlineData(41)] [InlineData(42)] public async Task Values(int value) { await Task.Yield(); Assert.True(value <= fixture.Value); output.WriteLine("async-output"); }
    [Fact(Skip = "intentional")] public void Skipped() { Assert.Fail(); }
}
'@
        Assert-Result (Invoke-Manifest (New-Manifest $source test)) 0 '(?s)async-output.*fixture-disposed.*total: 3.*succeeded: 2.*skipped: 1'
    }
    Test-Case 'remote-style scriptblock, Unicode, quotes, slashes and PowerShell-sensitive source' {
        $source = @'
using System;
namespace Fidelity;
public static class Program {
    public static void Main() {
        Console.WriteLine("æøå 日本語 😀 ' \" C:\\temp\\sample $HOME $(throw) ` & | ;");
    }
}
'@
        foreach ($newline in @("`n", "`r`n")) {
            $text = ($source -replace '\r\n|\n', $newline)
            Assert-Result (Invoke-Manifest (New-Manifest $text) -ScriptBlock) 0 ([regex]::Escape('æøå 日本語 😀 '' " C:\temp\sample $HOME $(throw) ` & | ;'))
        }
    }
    Test-Case 'direct Source, case normalization and duplicate identical pins' {
        Assert-Result (Invoke-Runner @{Mode='CONSOLE'; Framework='net11.0'; Source='System.Console.WriteLine("direct");'; DependsOn=@('Cuemon.Kernel@11.0.0','cuemon.kernel@11.0.0')}) 0 '(?m)^direct\r?$'
    }
    Test-Case 'direct UTF-8 file input' {
        Assert-Result (Invoke-Runner @{File="$PSScriptRoot/fixtures/DateSpan.cs"; DependsOn=@('Cuemon.Kernel@11.0.0')}) 0 '23,587,200 seconds'
    }
    Test-Case 'explicit and default clipboard normalize through actual runner' {
        foreach ($args in @(@{Clipboard=$true}, @{})) {
            Assert-Result (Invoke-Runner $args -ClipboardText 'System.Console.WriteLine("clipboard-source");') 0 '(?m)^clipboard-source\r?$'
        }
    }
    Test-Case 'unavailable clipboard diagnostic' {
        Assert-Result (Invoke-Runner @{} -ClipboardFailure) 1 'Clipboard unavailable'
    }
    Test-Case 'PowerShell help includes synopsis and examples' {
        $help = Get-Help $runner -Detailed
        if ($help.Synopsis -notmatch 'trusted C#' -or @($help.examples.example).Count -lt 4) { throw 'Help or examples missing.' }
    }
    Test-Case 'matching directive preamble is preserved' {
        Assert-Result (Invoke-Manifest (New-Manifest "#:property TargetFramework=net11.0`n#:sdk Microsoft.NET.Sdk`nSystem.Console.WriteLine(42);")) 0 '(?m)^42\r?$'
    }
    Test-Case 'matching pinned package directive with leading block comments' {
        Assert-Result (Invoke-Manifest (New-Manifest "/* header`ncomment */`n#:package Cuemon.Kernel@11.0.0`nSystem.Console.WriteLine(typeof(Cuemon.DateSpan).Name);" console @('Cuemon.Kernel@11.0.0'))) 0 '(?m)^DateSpan\r?$'
    }
    Test-Case 'duplicate source directives fail predictably' {
        Assert-Result (Invoke-Manifest (New-Manifest "#:property TargetFramework=net11.0`n#:property TargetFramework=net11.0`nSystem.Console.WriteLine(1);")) 1 'Duplicate source directive'
    }
    Test-Case 'C# preprocessor cannot hide floating source dependencies' {
        Assert-Result (Invoke-Manifest (New-Manifest "#nullable enable`n#:package Cuemon.Kernel@*`nSystem.Console.WriteLine(1);")) 1 'Invalid package pin'
    }
    Test-Case 'directive-like raw string contents are unmodified C#' {
        $source = @'
System.Console.WriteLine("""
#:package This.Is.Literal.Text@*
""");
'@
        Assert-Result (Invoke-Manifest (New-Manifest $source)) 0 '(?m)^#:package This.Is.Literal.Text@\*\r?$'
    }
    Test-Case 'unavailable exact pin cannot silently restore a higher version' {
        $r = Invoke-Manifest (New-Manifest 'System.Console.WriteLine(typeof(Cuemon.DateSpan).Name);' console @('Cuemon.Kernel@11.0.0-csrun-nonexistent'))
        Assert-Result $r 1 'NU1603'
    }
    Test-Case 'pinned prerelease is validated without discovery' {
        Assert-Result (Invoke-Runner @{DependsOn=@('Example.Package@1.2.3-preview.4'); Source='System.Console.WriteLine(1);'} -Environment @{PATH=''}) 1 'Missing .NET SDK'
    }
    Test-Case 'test source file preserves exact content including CRLF' {
        $source = @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Xunit;
namespace Fidelity;
public class Tests {
    [Fact] public void OriginalSource() {
        var path = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "Sample.cs");
        Assert.Equal(Environment.GetEnvironmentVariable("CSRUN_SOURCE_SHA256"), Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))));
    }
}
'@ -replace '\r\n|\n', "`r`n"
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source)))
        Assert-Result (Invoke-Runner @{ManifestJson=((New-Manifest $source test) | ConvertTo-Json)} -Environment @{CSRUN_SOURCE_SHA256=$hash}) 0 'succeeded: 1'
    }
    Test-Case 'current directory project is never selected' {
        $dir = Join-Path $root 'existing-project'; $null = New-Item -ItemType Directory $dir
        '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net11.0</TargetFramework></PropertyGroup><Target Name="Reject" BeforeTargets="Build"><Error Text="WRONG PROJECT" /></Target></Project>' | Set-Content "$dir/existing.csproj"
        Assert-Result (Invoke-Runner @{Source='System.Console.WriteLine("isolated");'} -WorkingDirectory $dir) 0 '(?m)^isolated\r?$'
    }
    Test-Case 'native console exit code and stderr' {
        Assert-Result (Invoke-Manifest (New-Manifest 'System.Console.Error.WriteLine("expected stderr"); return 23;')) 23 'expected stderr'
    }
    Test-Case 'unhandled program exception is visible and fails' {
        $result = Invoke-Manifest (New-Manifest 'throw new System.InvalidOperationException("expected exception");')
        if ($result.Code -eq 0) { throw 'Exception returned success.' }
        if (($result.Out + $result.Err) -notmatch 'expected exception') { throw 'Exception hidden.' }
    }
    Test-Case 'method-only program gets real compiler failure' {
        Assert-Result (Invoke-Manifest (New-Manifest 'public class Sample { public int Answer() => 42; }')) 1 'CS5001'
    }
    Test-Case 'no namespace-to-package inference' {
        Assert-Result (Invoke-Manifest (New-Manifest 'using Cuemon; System.Console.WriteLine(typeof(DateSpan));')) 1 'CS0246'
    }
    Test-Case 'restore failure remains visible and cleans test artifacts' {
        Assert-Result (Invoke-Manifest (New-Manifest 'using Xunit; public class Tests { [Fact] public void Pass() {} }' test @('Csrun.Nonexistent.Acceptance.Package@1.0.0'))) 1 'NU1101'
    }
    Test-Case 'ASP.NET explicit SDK console' {
        $m = New-Manifest 'System.Console.WriteLine(typeof(Microsoft.AspNetCore.Http.HttpContext).Name);'; $m.sdk='Microsoft.NET.Sdk.Web'; $m.frameworkReferences=@('Microsoft.AspNetCore.App')
        Assert-Result (Invoke-Manifest $m) 0 'HttpContext'
    }
    Test-Case 'ASP.NET framework reference and Web SDK test projects' {
        foreach ($sdk in @('Microsoft.NET.Sdk','Microsoft.NET.Sdk.Web')) {
            $m = New-Manifest 'using Xunit; public class Tests { [Fact] public void Http() { Assert.Equal("HttpContext", typeof(Microsoft.AspNetCore.Http.HttpContext).Name); } }' test
            $m.sdk=$sdk; $m.frameworkReferences=@('Microsoft.AspNetCore.App')
            Assert-Result (Invoke-Manifest $m) 0 'succeeded: 1'
        }
    }
    $invalidCases = @(
        @{Name='unknown schema'; Field='schemaVersion'; Value=2; Pattern='schemaVersion'},
        @{Name='noninteger schema'; Field='schemaVersion'; Value=1.0; Pattern='schemaVersion'},
        @{Name='method mode'; Field='mode'; Value='method'; Pattern='Unsupported mode'},
        @{Name='bad TFM'; Field='framework'; Value='win-x64'; Pattern='Invalid framework'},
        @{Name='MSBuild injection'; Field='framework'; Value='net11.0;Bad=1'; Pattern='Invalid framework'},
        @{Name='empty source'; Field='source'; Value=' '; Pattern='source'},
        @{Name='nonstring source'; Field='source'; Value=42; Pattern='source'},
        @{Name='conflicting pins'; Field='dependsOn'; Value=@('Cuemon.Kernel@11.0.0','cuemon.kernel@10.0.0'); Pattern='Conflicting'},
        @{Name='floating pin'; Field='dependsOn'; Value=@('Cuemon.Kernel@11.*'); Pattern='Invalid package pin'},
        @{Name='range pin'; Field='dependsOn'; Value=@('Cuemon.Kernel@[11.0.0,)'); Pattern='Invalid package pin'},
        @{Name='latest pin'; Field='dependsOn'; Value=@('Cuemon.Kernel@latest'); Pattern='Invalid package pin'},
        @{Name='missing version'; Field='dependsOn'; Value=@('Cuemon.Kernel'); Pattern='Invalid package pin'},
        @{Name='nonarray dependencies'; Field='dependsOn'; Value='Cuemon.Kernel@11.0.0'; Pattern='array'},
        @{Name='bad SDK'; Field='sdk'; Value='Bad.Sdk'; Pattern='Unsupported sdk'},
        @{Name='bad reference'; Field='frameworkReferences'; Value=@('$(Unsafe)'); Pattern='Invalid frameworkReferences'},
        @{Name='unknown field'; Field='surprise'; Value=$true; Pattern='Unknown manifest field'}
    )
    foreach ($case in $invalidCases) {
        Test-Case $case.Name { $m=New-Manifest; $m[$case.Field]=$case.Value; Assert-Result (Invoke-Manifest $m) 1 $case.Pattern }
    }
    foreach ($field in @('schemaVersion','mode','framework','source')) {
        Test-Case "missing $field" { $m=New-Manifest; $m.Remove($field); Assert-Result (Invoke-Manifest $m) 1 "Missing required manifest field '$field'" }
    }
    Test-Case 'malformed JSON' { Assert-Result (Invoke-Runner @{ManifestJson='{oops'}) 1 'Invalid manifest JSON' }
    Test-Case 'nonobject JSON' { Assert-Result (Invoke-Runner @{ManifestJson='[]'}) 1 'JSON object' }
    foreach ($config in @('Mode','Framework','Source','File','Clipboard','DependsOn')) {
        Test-Case "manifest conflicts with $config" {
            $args = @{ManifestJson=((New-Manifest) | ConvertTo-Json)}
            $args[$config] = switch ($config) { 'Clipboard' {$true} 'DependsOn' {@('A@1.0.0')} default {'value'} }
            Assert-Result (Invoke-Runner $args) 1 'mutually exclusive'
        }
    }
    Test-Case 'conflicting sources' { Assert-Result (Invoke-Runner @{Source='x';File='x'}) 1 'mutually exclusive' }
    Test-Case 'clipboard and source conflict' { Assert-Result (Invoke-Runner @{Source='x';Clipboard=$true}) 1 'mutually exclusive' }
    Test-Case 'missing file diagnostic' { Assert-Result (Invoke-Runner @{File=(Join-Path $root 'missing.cs')}) 1 'does not exist' }
    foreach ($directive in @('#:property TargetFramework=net10.0','#:package Cuemon.Kernel@10.0.0','#:sdk Microsoft.NET.Sdk.Web','#:package Cuemon.Kernel@*','#:property TargetFrameworks=net10.0;net11.0')) {
        Test-Case "conflicting directive $directive" { Assert-Result (Invoke-Manifest (New-Manifest "$directive`nSystem.Console.WriteLine(1);")) 1 'conflicts|Invalid package pin|Unsupported source directive' }
    }
    Test-Case 'incompatible xUnit pin' { Assert-Result (Invoke-Manifest (New-Manifest 'class T {}' test @('xunit.v3@3.0.0'))) 1 'Incompatible xunit.v3' }
    Test-Case 'missing dotnet executable' { Assert-Result (Invoke-Runner @{Source='System.Console.WriteLine(1);'} -Environment @{PATH=''}) 1 'Missing .NET SDK' }
    Test-Case 'unavailable SDK via global.json gives actionable diagnostic' {
        $dir = Join-Path $root 'unavailable-sdk'; $null = New-Item -ItemType Directory $dir
        '{"sdk":{"version":"99.0.100","rollForward":"disable"}}' | Set-Content "$dir/global.json"
        Assert-Result (Invoke-Runner @{Source='System.Console.WriteLine(1);'} -WorkingDirectory $dir) 1 'global.json'
    }
    Test-Case 'unavailable TFM is never retargeted' {
        Assert-Result (Invoke-Runner @{Framework='net99.0'; Source='System.Console.WriteLine(1);'}) 1 'NETSDK1045'
    }
    Test-Case 'all test artifact directories removed after success and failure' {
        # Each test summary reveals the unique project path; runner must clean it.
        $r=Invoke-Manifest (New-Manifest 'using Xunit; public class T { [Fact] public void Pass() {} }' test)
        Assert-Result $r 0 'succeeded: 1'
        if ($r.Out -notmatch '(?<path>[^\r\n]*csrun-[a-f0-9]{32})[\\/]bin[\\/]') { throw 'No test artifact path in summary.' }
        $path = $Matches.path.Trim() -replace '^.* - ', ''
        if (Test-Path -LiteralPath $path) { throw "Leaked artifacts: $path" }
        if (@(Get-ChildItem -LiteralPath $root -Directory -Filter 'csrun-*').Count) { throw 'Leaked test artifacts from an earlier success or failure.' }
    }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($root)
    if (-not $resolvedRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -or [IO.Path]::GetFileName($resolvedRoot) -notlike 'csrun-tests-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
Write-Host "Tests: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
exit 0
