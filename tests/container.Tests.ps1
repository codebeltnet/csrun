#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Image,
    [Parameter(Mandatory)][string[]] $SdkVersion,
    [ValidateSet('linux/amd64', 'linux/arm64')][string] $Platform = 'linux/amd64',
    [switch] $RequireNative,
    [string] $DockerContext,
    [string] $EngineUrl = 'https://github.com/codebeltnet/csrun/releases/latest/download/csrun.ps1',
    [string] $EngineSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$passed = 0; $failed = 0
$docker = (Get-Command docker -CommandType Application | Select-Object -First 1).Source
function Invoke-Docker([string[]] $Arguments, [string] $InputText = '') {
    $containerName = $null
    if ($Arguments.Count -gt 0 -and $Arguments[0] -eq 'run') {
        $containerName = 'csrun-test-' + [guid]::NewGuid().ToString('N')
        $Arguments = @('run', '--name', $containerName) + $Arguments[1..($Arguments.Count - 1)]
    }
    if ($DockerContext) { $Arguments = @('--context', $DockerContext) + $Arguments }
    $start = [Diagnostics.ProcessStartInfo]::new($docker)
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw 'Docker test timed out after 300 seconds.' }
        $out = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult()
        return @{ Code=$process.ExitCode; Out=$out; Err=$err; Text=($out + "`n" + $err -replace '\x1B\[[0-?]*[ -/]*[@-~]', '') }
    } finally {
        if ($containerName -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        if ($containerName -and $process.ExitCode -ne 0) {
            $contextArgs = if ($DockerContext) { @('--context', $DockerContext) } else { @() }
            & $docker @contextArgs rm --force $containerName 2>$null | Out-Null
        }
        $process.Dispose()
    }
}
function Assert-Result($Result, [int] $Code = 0, [string] $Pattern = '') {
    if ($Result.Code -ne $Code -or ($Pattern -and $Result.Text -notmatch $Pattern)) { throw "Expected exit $Code and /$Pattern/; got $($Result.Code):`n$($Result.Text)" }
}
function Assert-NoWorkloadWarning($Result) {
    if ($Result.Text -match 'An issue was encountered verifying workloads') { throw "Unexpected workload integrity warning:`n$($Result.Text)" }
}
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name`n$_" }
}
function Invoke-Manifest([hashtable] $Manifest, [switch] $Hardened) {
    $options = if ($Hardened) { @('--read-only', '--tmpfs', '/tmp:rw,exec,nosuid,nodev,size=1g,mode=1777', '--cap-drop=ALL', '--security-opt=no-new-privileges', '--cpus=2', '--memory=2g', '--pids-limit=256') } else { @() }
    Invoke-Docker (@('run', '--rm', '-i', '--platform', $Platform) + $options + @($Image)) ($Manifest | ConvertTo-Json -Depth 10 -Compress)
}
function New-Manifest([string] $Source, [string] $Mode = 'console', [string] $Framework = $script:framework) {
    @{schemaVersion=1; mode=$Mode; framework=$Framework; source=$Source}
}
$channels = @($SdkVersion | ForEach-Object { ($_ -split '\.')[0..1] -join '.' })
$framework = 'net' + ($channels | Sort-Object { [version]$_ } | Select-Object -First 1)
Test-Case 'native CPU, image architecture, PowerShell and .NET runtime architecture' {
    $expectedCpu = ($Platform -split '/')[1]
    if ($RequireNative) {
        $hostCpu = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant().Replace('x64', 'amd64')
        if (-not $DockerContext -and $hostCpu -cne $expectedCpu) { throw "Native runner required: $hostCpu != $expectedCpu" }
        $daemon = Invoke-Docker @('info', '--format', '{{.Architecture}}')
        Assert-Result $daemon 0 $(if ($expectedCpu -eq 'amd64') { '^(x86_64|amd64)\s*$' } else { '^(aarch64|arm64)\s*$' })
    }
    $config = Invoke-Docker @('image', 'inspect', $Image)
    Assert-Result $config
    if (@($config.Out | ConvertFrom-Json)[0].Architecture -cne $expectedCpu) { throw 'Image CPU mismatch.' }
    $runtimeCpu = if ($expectedCpu -eq 'amd64') { 'X64' } else { 'Arm64' }
    Assert-Result (Invoke-Docker @('run', '--rm', '--platform', $Platform, '--entrypoint', 'pwsh', $Image, '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()')) 0 '^7\.'
    Assert-Result (Invoke-Manifest (New-Manifest 'Console.WriteLine(System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture);')) 0 "(?m)^$runtimeCpu\r?$"
}
Test-Case 'exact installed SDK and associated runtime inventories' {
    $sdks = Invoke-Docker @('run', '--rm', '--platform', $Platform, '--entrypoint', 'dotnet', $Image, '--list-sdks')
    $runtimes = Invoke-Docker @('run', '--rm', '--platform', $Platform, '--entrypoint', 'dotnet', $Image, '--list-runtimes')
    Assert-Result $sdks; Assert-Result $runtimes
    foreach ($inventory in @(@{ Option='--list-sdks'; Result=$sdks }, @{ Option='--list-runtimes'; Result=$runtimes })) {
        $defaultCheck = Invoke-Docker @('run', '--rm', '--platform', $Platform, '-e', 'DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=false', '--entrypoint', 'dotnet', $Image, $inventory.Option)
        Assert-Result $defaultCheck
        if ($defaultCheck.Out -cne $inventory.Result.Out) { throw "Workload integrity setting changed $($inventory.Option) inventory." }
    }
    Write-Host $sdks.Out; Write-Host $runtimes.Out
    $installed = @($sdks.Out -split '\r?\n' | Where-Object { $_ } | ForEach-Object { ($_ -split ' ')[0] })
    if (@(Compare-Object $SdkVersion $installed).Count) { throw 'SDK inventory differs from explicit build inputs.' }
    $index = (Invoke-RestMethod 'https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json').'releases-index'
    $expected = @()
    foreach ($channel in $channels) {
        $metadata = Invoke-RestMethod ($index | Where-Object { $_.'channel-version' -ceq $channel }).'releases.json'
        foreach ($version in $SdkVersion | Where-Object { $_.StartsWith("$channel.") }) {
            $release = $metadata.releases | Where-Object { $version -cin @($_.sdks.version) } | Select-Object -First 1
            $expected += "Microsoft.NETCore.App $($release.runtime.version)"
            $expected += "Microsoft.AspNetCore.App $($release.'aspnetcore-runtime'.version)"
        }
    }
    $actual = @($runtimes.Out -split '\r?\n' | Where-Object { $_ } | ForEach-Object { ($_ -split ' ')[0..1] -join ' ' })
    if (@(Compare-Object @($expected | Select-Object -Unique) $actual).Count) { throw 'Runtime inventory differs from requested SDK-associated runtimes.' }
}
Test-Case 'container workload integrity default and explicit override' {
    $config = Invoke-Docker @('image', 'inspect', $Image)
    Assert-Result $config
    if ('DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=true' -cnotin @($config.Out | ConvertFrom-Json)[0].Config.Env) { throw 'Missing container workload integrity default.' }
    Assert-Result (Invoke-Manifest (New-Manifest 'Console.WriteLine(Environment.GetEnvironmentVariable("DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK"));')) 0 '(?m)^true\r?$'
    # Observe the override in the entry point's process before SDK execution; the
    # restored workload check itself need not succeed in this disposable image.
    $command = '[Console]::WriteLine($env:DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK); & /opt/csrun/container-entrypoint.ps1'
    Assert-Result (Invoke-Docker @('run', '--rm', '-i', '--platform', $Platform, '-e', 'DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=false', '--entrypoint', 'pwsh', $Image, '-NoProfile', '-Command', $command) '{bad') 1 '(?m)^false\r?$'
}
Test-Case 'bundled release asset hash and image metadata' {
    $config = Invoke-Docker @('image', 'inspect', $Image)
    Assert-Result $config
    $info = @($config.Out | ConvertFrom-Json)[0]
    $labels = $info.Config.Labels
    if (-not $EngineSha256) { $script:EngineSha256 = $labels.'net.codebelt.csrun.engine.sha256' }
    $hash = Invoke-Docker @('run', '--rm', '--platform', $Platform, '--entrypoint', 'sha256sum', $Image, '/opt/csrun/csrun.ps1')
    Assert-Result $hash 0 "^$EngineSha256 "
    if ($labels.'net.codebelt.csrun.engine.sha256' -cne $EngineSha256 -or $labels.'net.codebelt.csrun.engine.release' -notmatch '^v\d+\.\d+\.\d+' -or $labels.'net.codebelt.csrun.engine.url' -cne $EngineUrl) { throw 'Engine identity labels are missing or inconsistent.' }
}
foreach ($channel in $channels) {
    Test-Case "console stdin executes net$channel" {
        $result = Invoke-Manifest (New-Manifest 'Console.WriteLine(42);' -Framework "net$channel")
        Assert-Result $result 0 '(?m)^42\r?$'
        Assert-NoWorkloadWarning $result
    }
    Test-Case "genuine xUnit discovery and passing Fact net$channel" {
        $result = Invoke-Manifest (New-Manifest 'using Xunit; public class SmokeTest { [Fact] public void Pass() => Assert.True(true); }' test "net$channel")
        Assert-Result $result 0 'total:\s+1'
        Assert-NoWorkloadWarning $result
        if ($result.Text -notmatch 'succeeded:\s+1' -or $result.Text -notmatch 'failed:\s+0') { throw $result.Text }
        Write-Host $result.Text
    }
}
Test-Case 'complete explicit Main and program stderr/exit status' {
    Assert-Result (Invoke-Manifest (New-Manifest 'using System; class Program { static int Main() { Console.WriteLine("main"); Console.Error.WriteLine("stderr"); return 23; } }')) 23 'stderr'
}
Test-Case 'pinned Codebelt console dependency' {
    $manifest = Get-Content "$PSScriptRoot/../samples/datespan.json" -Raw | ConvertFrom-Json -AsHashtable
    $manifest.framework = $framework
    Assert-Result (Invoke-Manifest $manifest) 0 '273 days'
}
Test-Case 'pinned Codebelt test dependency and visible MTP live output' {
    $manifest = New-Manifest (Get-Content "$PSScriptRoot/fixtures/OutputLinesTest.cs" -Raw) test
    $manifest.dependsOn = @('Codebelt.Extensions.Xunit@13.0.0')
    $result = Invoke-Manifest $manifest
    Assert-Result $result 0 'succeeded:\s+1'
    foreach ($line in @('started', '2', 'finished')) { if ($result.Text -notmatch "(?m)^OUTPUT: .*\] $line\r?$") { throw "Missing live output '$line': $($result.Text)" } }
    Write-Host $result.Text
}
Test-Case 'Git preserves real MinVer package build behavior' {
    $manifest = New-Manifest 'using System.Reflection; Console.WriteLine(Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion);'
    $manifest.dependsOn = @('MinVer@8.0.0')
    $repository = 'git config --global --add safe.directory /tmp; git -C /tmp init -q; git -C /tmp -c user.name=csrun-test -c user.email=test@example.invalid commit --allow-empty -qm fixture; git -C /tmp tag 1.2.3; '
    $entrypoint = 'exec pwsh -NoProfile -NonInteractive -File /opt/csrun/container-entrypoint.ps1'
    $inputJson = $manifest | ConvertTo-Json -Compress
    Assert-Result (Invoke-Docker @('run', '--rm', '-i', '--platform', $Platform, '--entrypoint', 'sh', $Image, '-c', ($repository + $entrypoint)) $inputJson) 0 '(?m)^1\.2\.3\+'
    # MinVer falls back to a default version when git cannot discover the repo.
    # Retaining git prevents that observable compatibility regression.
    $noGit = 'mkdir /tmp/no-git; printf "#!/bin/sh\nexit 127\n" > /tmp/no-git/git; chmod +x /tmp/no-git/git; export PATH=/tmp/no-git:$PATH; '
    Assert-Result (Invoke-Docker @('run', '--rm', '-i', '--platform', $Platform, '--entrypoint', 'sh', $Image, '-c', ($repository + $noGit + $entrypoint)) $inputJson) 0 '(?m)^0\.0\.0-alpha\.0'
}
Test-Case 'compilation failure remains nonzero' {
    Assert-Result (Invoke-Manifest (New-Manifest 'this is not C#;')) 1 'error CS'
}
Test-Case 'failing xUnit assertion preserves MTP exit 2' {
    $result = Invoke-Manifest (New-Manifest 'using Xunit; public class T { [Fact] public void Fail() => Assert.True(false); }' test)
    Assert-Result $result 2 'failed:\s+1'
    if ($result.Text -notmatch 'Assert.True\(\) Failure') { throw "Missing assertion diagnostic: $($result.Text)" }
}
Test-Case 'no tests preserves MTP exit 8' {
    Assert-Result (Invoke-Manifest (New-Manifest 'public class NoTests { }' test)) 8 'total:\s+0'
}
Test-Case 'multiline quotes apostrophes Unicode and escaped characters' {
    $source = @'
using System;
Console.WriteLine("æøå 世界 🚀 \"quotes\" apostrophe's \\slash");
Console.WriteLine("line\nnext\ttab");
'@
    Assert-Result (Invoke-Manifest (New-Manifest $source)) 0 'æøå 世界 🚀 "quotes" apostrophe''s \\slash'
}
Test-Case 'large manifest is not truncated' {
    $source = '/*' + ('transport ' * 30000) + '*/ Console.WriteLine("large complete");'
    Assert-Result (Invoke-Manifest (New-Manifest $source)) 0 'large complete'
}
Test-Case 'invalid JSON and empty stdin' {
    Assert-Result (Invoke-Docker @('run', '--rm', '-i', '--platform', $Platform, $Image) '{bad') 1 'Invalid manifest JSON'
    Assert-Result (Invoke-Docker @('run', '--rm', '-i', '--platform', $Platform, $Image)) 1 'Expected a UTF-8 JSON manifest'
}
Test-Case 'unsupported framework and conflicting pins fail' {
    Assert-Result (Invoke-Manifest (New-Manifest 'Console.WriteLine(42);' -Framework net9.0)) 1 'framework|supported'
    Assert-Result (Invoke-Manifest (New-Manifest 'Console.WriteLine(42);' -Framework net48)) 1 'only supported natively on Windows'
    $manifest = New-Manifest 'Console.WriteLine(42);'
    $manifest.dependsOn = @('Cuemon.Kernel@11.0.0', 'Cuemon.Kernel@11.0.1')
    Assert-Result (Invoke-Manifest $manifest) 1 'conflict'
}
if ($channels.Count -eq 1) {
    Test-Case 'missing target fails without retargeting' {
        $missing = if ($channels[0] -eq '10.0') { 'net11.0' } else { 'net10.0' }
        Assert-Result (Invoke-Manifest (New-Manifest 'Console.WriteLine(42);' -Framework $missing)) 1 'cannot build|Missing .*runtime'
    }
}
Test-Case 'omitted framework retains engine LTS default' {
    $manifest = New-Manifest 'Console.WriteLine(42);'
    $manifest.Remove('framework')
    $result = Invoke-Manifest $manifest
    # Current supported GA LTS must be present; otherwise the engine must fail.
    $index = (Invoke-RestMethod 'https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json').'releases-index'
    $lts = $index | Where-Object { $_.'release-type' -eq 'lts' -and $_.'support-phase' -in @('active','maintenance') -and $_.'latest-release' -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.'channel-version' } -Descending | Select-Object -First 1
    if ($lts.'channel-version' -in $channels) { Assert-Result $result 0 "net$($lts.'channel-version')" }
    else { Assert-Result $result 1 'Missing .*runtime' }
}
Test-Case 'ASP.NET shared framework is usable by tests' {
    $manifest = New-Manifest 'using Xunit; using Microsoft.AspNetCore.Http; public class T { [Fact] public void Pass() => Assert.Equal(200, new DefaultHttpContext().Response.StatusCode); }' test
    $manifest.frameworkReferences = @('Microsoft.AspNetCore.App')
    Assert-Result (Invoke-Manifest $manifest) 0 'succeeded:\s+1'
}
Test-Case 'non-root and no implicit host mounts; disposable storage' {
    $name = 'csrun-isolation-' + [guid]::NewGuid().ToString('N')
    try {
        Assert-Result (Invoke-Docker @('create', '--name', $name, '--platform', $Platform, '--entrypoint', 'sh', $Image, '-c', 'id -u; echo isolated > /tmp/csrun-marker'))
        $inspect = Invoke-Docker @('inspect', $name)
        Assert-Result $inspect
        $info = @($inspect.Out | ConvertFrom-Json)[0]
        if ($info.Mounts.Count -or $info.HostConfig.Privileged -or $info.Config.User -in @('', '0', 'root')) { throw 'Unsafe default container configuration.' }
        $result = Invoke-Docker @('start', '--attach', $name)
        Assert-Result $result 0 '(?m)^[1-9][0-9]*\r?$'
    } finally { Assert-Result (Invoke-Docker @('rm', '--force', $name)) }
    $removed = Invoke-Docker @('inspect', $name)
    if ($removed.Code -eq 0) { throw 'Container storage was not removed.' }
    Assert-Result (Invoke-Docker @('run', '--rm', '--platform', $Platform, '--entrypoint', 'sh', $Image, '-c', 'test ! -e /tmp/csrun-marker'))
}
Test-Case 'read-only root, writable executable tmpfs and resource restrictions' {
    $console = Invoke-Manifest (New-Manifest 'Console.WriteLine("hardened console");') -Hardened
    Assert-Result $console 0 'hardened console'
    Assert-NoWorkloadWarning $console
    $test = Invoke-Manifest (New-Manifest 'using Xunit; public class T { [Fact] public void Pass() => Assert.True(true); }' test) -Hardened
    Assert-Result $test 0 'succeeded:\s+1'
    Assert-NoWorkloadWarning $test
    Assert-Result (Invoke-Manifest (New-Manifest 'using Xunit; public class T { [Fact] public void Fail() => Assert.True(false); }' test) -Hardened) 2 'failed:\s+1'
}
Test-Case 'bundled engine validates input without network access' {
    # Invalid JSON is rejected by csrun itself before metadata/NuGet access.
    # This proves startup does not need GitHub to retrieve the engine, while
    # ordinary execution intentionally retains network access for dependencies.
    Assert-Result (Invoke-Docker @('run', '--rm', '-i', '--platform', $Platform, '--network', 'none', $Image) '{bad') 1 'Invalid manifest JSON'
}
Write-Host "Container tests ($Platform): $passed passed, $failed failed"
$global:LASTEXITCODE = [int]($failed -gt 0)
if ($MyInvocation.MyCommand -is [System.Management.Automation.ExternalScriptInfo]) { exit $LASTEXITCODE }
