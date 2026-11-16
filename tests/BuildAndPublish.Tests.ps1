#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module "$PSScriptRoot/../BuildAndPublish.psm1" -Force -PassThru
$passed = 0; $failed = 0
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name`n$_" }
}
function Assert-Throws([scriptblock] $Body, [string] $Pattern) {
    try { & $Body; throw 'Expected rejection.' } catch { if ($_ -notmatch $Pattern) { throw } }
}
Test-Case 'SDK-specific tags and PassThru with WhatIf' {
    foreach ($case in @(
        @{Versions=@('10.0.404'); Tags=@('10.0.404','10.0','10')},
        @{Versions=@('11.0.100'); Tags=@('11.0.100','11.0','11')},
        @{Versions=@('10.0.404','11.0.100'); Tags=@('10.0.404-11.0.100','10.0-11.0','10-11')}
    )) {
        $plan = BuildAndPublish -SdkVersion $case.Versions -WhatIf -PassThru
        $actual = @($plan.Tags | ForEach-Object { ($_ -split ':')[-1] })
        if (@(Compare-Object $actual $case.Tags).Count -or $plan.Published -or $plan.EngineVersion -or $plan.BaseImage) { throw 'Invalid dry-run plan, or WhatIf resolved external state.' }
        if ($plan.Repository -cne 'docker.io/codebeltnet/' -or $plan.Dockerfile -cne './csrun.Dockerfile') { throw 'Unexpected defaults.' }
        if ($plan.VersionedTags.Count -ne 0 -or $plan.UnresolvedVersionedTags.Count -ne 3) { throw 'Missing unresolved release aliases.' }
        $known = BuildAndPublish -SdkVersion $case.Versions -EngineVersion v0.2.2 -WhatIf -PassThru
        $expected = @($case.Tags) + @($case.Tags | ForEach-Object { "$_-v0.2.2" })
        if (($known.Tags -join ',') -cne (($expected | ForEach-Object { "docker.io/codebeltnet/csrun:$_" }) -join ',') -or $known.VersionedTags.Count -ne 3 -or $known.ConvenienceTags.Count -ne 3 -or $known.UnresolvedVersionedTags.Count) { throw 'Release tagging matrix differs.' }
    }
}
Test-Case 'release identities and Docker length limits are validated without side effects' {
    foreach ($version in @('', '0.2.2','v01.2.3','v1.2.3-rc.1','latest','v1.2')) {
        Assert-Throws { BuildAndPublish 10.0.404 -EngineVersion $version -WhatIf } 'Engine release'
    }
    Assert-Throws { BuildAndPublish 10.0.404 -EnginePath ./csrun.ps1 -WhatIf } 'explicit release'
    $sdk = '11.0.100-' + ('a' * 119)
    $null = BuildAndPublish $sdk -WhatIf -PassThru
    Assert-Throws { BuildAndPublish $sdk -EngineVersion v0.2.2 -WhatIf } 'overlong'
    & $module {
        function Invoke-RestMethod { throw 'Network forbidden.' }
        function Invoke-WebRequest { throw 'Network forbidden.' }
        function docker { throw 'Docker forbidden.' }
        function python { throw 'Python forbidden.' }
        try {
            $plan = BuildAndPublish 11.0.100-rc.1.26425.128 -EnginePath missing.ps1 -EngineVersion v0.2.2 -BuildOnly -Registry localhost:5000/fork -EngineRepository fork/csrun -WhatIf -PassThru
            if ($plan.VersionedTags[0] -cne 'localhost:5000/fork/csrun:11.0.100-rc.1-v0.2.2') { throw 'Prerelease or custom destination changed.' }
            $null = BuildAndPublish 10.0.404 -WhatIf -PassThru
        } finally { Remove-Item Function:Invoke-RestMethod, Function:Invoke-WebRequest, Function:docker, Function:python }
    }
}
Test-Case 'reference prerelease normalization preserves exact SDK input' {
    $plan = BuildAndPublish '11.0.100-rc.1.26425.128' -WhatIf -PassThru
    if ($plan.PublishTags -cne '11.0.100-rc.1' -or $plan.SdkVersions -cne '11.0.100-rc.1.26425.128') { throw 'Prerelease normalization changed.' }
}
Test-Case 'duplicate and ambiguous SDK channels are rejected' {
    Assert-Throws { BuildAndPublish 10.0.404 10.0.404 -WhatIf } 'unique'
    Assert-Throws { BuildAndPublish 10.0.404 10.0.115 -WhatIf } 'unique'
    Assert-Throws { BuildAndPublish 11.0.100-rc.1.26425.128 11.0.100-rc.1.26425.129 -WhatIf } 'unique'
}
Test-Case 'invalid, older and floating SDK inputs fail' {
    foreach ($version in @('9.0.100','latest','10.0','10.0.*','10.0.404;whoami','10.0.404-invalid suffix')) { Assert-Throws { BuildAndPublish $version -WhatIf } 'SDK|tag' }
}
Test-Case 'custom image, registry and Dockerfile options' {
    $plan = BuildAndPublish 10.0.404 -ImageName custom -Registry localhost:5000/team -Dockerfile ./custom.Dockerfile -WhatIf -PassThru
    if ($plan.Tags[0] -cne 'localhost:5000/team/custom:10.0.404' -or $plan.Dockerfile -cne './custom.Dockerfile') { throw 'Custom options were lost.' }
}
Test-Case 'publication aliases are absent' {
    if ((Get-Command BuildAndPublish).Parameters.ContainsKey('Latest')) { throw 'Unexpected Latest parameter.' }
}
Test-Case 'manual builds support independent registry and native Docker contexts' {
    $contexts = @{ 'linux/amd64'='my-amd64'; 'linux/arm64'='my-arm64' }
    $builders = @{ 'linux/amd64'='builder-amd64'; 'linux/arm64'='builder-arm64' }
    $plan = BuildAndPublish 10.0.404 11.0.100 -Registry registry.example/team -DockerContext $contexts -Builder $builders -WhatIf -PassThru
    if ($plan.Tags[0] -cne 'registry.example/team/csrun:10.0.404-11.0.100' -or $plan.Platforms.Count -ne 2 -or $plan.DockerContexts['linux/arm64'] -cne 'my-arm64' -or $plan.Builders['linux/amd64'] -cne 'builder-amd64') { throw 'Independent manual build plan changed.' }
}
Test-Case 'a foreign CPU fails before downloads rather than using emulation' {
    & $module {
        function docker { $global:LASTEXITCODE = 0; 'linux/x86_64' }
        try {
            $rejected = $false
            try { BuildAndPublish 10.0.404 -BuildOnly -Platform linux/arm64 } catch { $rejected = $_ -match 'Native Docker host required for linux/arm64' }
            if (-not $rejected) { throw 'Foreign Docker CPU was accepted.' }
        } finally { Remove-Item Function:docker }
    }
}
Test-Case 'unavailable Skopeo transport fails before downloads or builds' {
    & $module {
        function docker { $global:LASTEXITCODE = 0; 'linux/x86_64' }
        function python {
            if ($args[-1] -cne 'check-skopeo') { throw 'Expected transport preflight.' }
            $global:LASTEXITCODE = 1
        }
        function Invoke-RestMethod { throw 'External metadata should not be downloaded.' }
        try {
            $rejected = $false
            try { BuildAndPublish 10.0.404 -BuildOnly -Platform linux/amd64 } catch { $rejected = $_ -match 'Remote utility Docker daemons require native Skopeo' }
            if (-not $rejected) { throw 'Missing native Skopeo was not rejected before construction.' }
        } finally {
            Remove-Item Function:docker, Function:python, Function:Invoke-RestMethod
        }
    }
}
Test-Case 'unsupported/EOL metadata channels fail before exact SDK lookup' {
    $fixture = (Get-Content "$PSScriptRoot/fixtures/releases-index.json" -Raw | ConvertFrom-Json -AsHashtable)['releases-index']
    & $module {
        param($Index)
        foreach ($version in @('9.0.100','12.0.100','99.0.100')) {
            $rejected = $false
            try { Get-CsrunSdkRelease $version $Index } catch { $rejected = $_ -match 'unsupported|EOL' }
            if (-not $rejected) { throw "Did not reject $version." }
        }
    } $fixture
}
Test-Case 'native Docker errors are not swallowed' {
    & $module {
        function docker { $global:LASTEXITCODE = 37 }
        try {
            $rejected = $false
            try { Invoke-CsrunDocker @('buildx','version') } catch { $rejected = $_ -match 'exit 37' }
            if (-not $rejected) { throw 'Docker failure was lost.' }
        } finally { Remove-Item Function:docker }
    }
}
Test-Case 'exact historical SDK lookup uses channel metadata without substitution' {
    & $module {
        function Invoke-RestMethod { param($Uri) @{releases=@(@{sdks=@(@{version='10.0.115'; files=@()})})} }
        try {
            $index = @(@{product='.NET'; 'channel-version'='10.0'; 'release-type'='lts'; 'support-phase'='active'; 'latest-sdk'='10.0.404'; 'releases.json'='https://example.invalid/releases.json'})
            if ((Get-CsrunSdkRelease '10.0.115' $index).version -cne '10.0.115') { throw 'Historical SDK was substituted.' }
            $rejected = $false
            try { Get-CsrunSdkRelease '10.0.999' $index } catch { $rejected = $_ -match 'Exact SDK.*absent' }
            if (-not $rejected) { throw 'Unknown exact SDK was accepted.' }
        } finally { Remove-Item Function:Invoke-RestMethod }
    }
}
Test-Case 'downloaded fork release is authoritative and explicit versions must match' {
    & $module {
        $destination = Join-Path ([IO.Path]::GetTempPath()) ('csrun-engine-test-' + [guid]::NewGuid().ToString('N'))
        $script:release = @{id=123; draft=$false; prerelease=$false; tag_name='v1.2.3'; assets=@(@{name='csrun.ps1'; digest='sha256:6f5237ab16b004222196b68b22fbca3273d5803611518e1b3f2bcb303e0ab7637'; size=6})}
        function Invoke-RestMethod { param($Uri) if ($Uri -cne 'https://api.github.com/repos/fork/csrun/releases/latest') { throw 'Unexpected repository.' }; $script:release }
        function Invoke-WebRequest { param($Uri, $OutFile) if ($Uri -cne 'https://github.com/fork/csrun/releases/latest/download/csrun.ps1') { throw 'Unexpected download.' }; [IO.File]::WriteAllText($OutFile, 'engine') }
        try {
            # Use a fixture hash computed independently from the acquisition path.
            $script:release.assets[0].digest = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('engine'))).ToLowerInvariant()
            $actual = Get-CsrunPublishedEngine fork/csrun $destination ''
            if ($actual.Release.tag_name -cne 'v1.2.3') { throw 'Lost authoritative engine identity.' }
            $null = Get-CsrunPublishedEngine fork/csrun $destination v1.2.3
            Assert-Throws { Get-CsrunPublishedEngine fork/csrun $destination v1.2.4 } 'differs from the authoritative'
            foreach ($tag in @('', 'v01.2.3', 'v1.2.3-rc.1')) {
                $script:release.tag_name = $tag
                Assert-Throws { Get-CsrunPublishedEngine fork/csrun $destination '' } 'verifiable'
            }
            $script:release.tag_name = 'v1.2.3'
            $script:release.assets[0].digest = 'sha256:' + ('0' * 64)
            Assert-Throws { Get-CsrunPublishedEngine fork/csrun $destination '' } 'integrity'
        } finally {
            Remove-Item Function:Invoke-RestMethod, Function:Invoke-WebRequest
            if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination }
            Remove-Variable release -Scope Script
        }
    }
}
Write-Host "BuildAndPublish tests: $passed passed, $failed failed"
exit ([int]($failed -gt 0))
