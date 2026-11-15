function Resolve-DotNetSdkTagSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SdkVersion
    )

    $trimmedVersion = $SdkVersion.Trim()
    $match = [regex]::Match($trimmedVersion, '^(?<Major>\d+)\.(?<Minor>\d+)\.(?<Feature>\d+)(?<Suffix>-.+)?$')

    if (-not $match.Success) {
        throw "Unsupported .NET SDK version '$SdkVersion'. Expected forms like '10.0.404' or '11.0.100-rc.1.26425.128'."
    }

    $major = $match.Groups['Major'].Value
    $minor = $match.Groups['Minor'].Value
    $feature = $match.Groups['Feature'].Value
    $suffix = $match.Groups['Suffix'].Value

    $coreVersion = '{0}.{1}.{2}' -f $major, $minor, $feature
    $publishTag = $trimmedVersion

    if ($suffix) {
        $suffixSegments = $suffix.TrimStart('-').Split('.')
        $hasBuildSuffix = $suffixSegments.Count -ge 4 -and
            [regex]::IsMatch($suffixSegments[-1], '^\d+$') -and
            [regex]::IsMatch($suffixSegments[-2], '^\d+$')

        if ($hasBuildSuffix) {
            $publishTag = '{0}-{1}' -f $coreVersion, ($suffixSegments[0..($suffixSegments.Count - 3)] -join '.')
        }
    }

    [pscustomobject]@{
        FullVersion   = $trimmedVersion
        MajorTag      = $major
        MajorMinorTag = '{0}.{1}' -f $major, $minor
        PublishTag    = $publishTag
    }
}

function Assert-UniqueResolvedTags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$ResolvedVersion
    )

    $duplicateChecks = @{
        MajorTag      = 'major'
        MajorMinorTag = 'major.minor'
        PublishTag    = 'publish'
    }

    foreach ($entry in $duplicateChecks.GetEnumerator()) {
        $duplicates = $ResolvedVersion |
            Group-Object -Property $entry.Key |
            Where-Object Count -gt 1 |
            Select-Object -ExpandProperty Name

        if ($duplicates) {
            throw "Each SDK version must resolve to a unique $($entry.Value) tag. Duplicates: $($duplicates -join ', ')."
        }
    }
}

function Get-CsrunSdkRelease($Version, $Index) {
    $channel = ($Version -split '\.')[0..1] -join '.'
    $entry = @($Index | Where-Object { $_.product -eq '.NET' -and $_.'channel-version' -ceq $channel })
    if ([version]$channel -lt [version]'10.0' -or $entry.Count -ne 1) { throw "Unsupported SDK channel '$channel'." }
    $entry = $entry[0]
    $supported = $entry.'release-type' -in @('lts', 'sts') -and $entry.'support-phase' -in @('active', 'maintenance')
    $preview = @($Index | Where-Object { $_.'release-type' -in @('lts', 'sts') -and $_.'support-phase' -in @('preview', 'go-live') } | Sort-Object { [version]$_.'channel-version' } -Descending | Select-Object -First 1)
    if (-not $supported -and -not ($preview.Count -eq 1 -and $preview[0].'channel-version' -ceq $channel)) { throw "SDK channel '$channel' is unsupported or EOL." }
    $metadata = Invoke-RestMethod -Uri $entry.'releases.json'
    $sdks = @($metadata.releases | ForEach-Object { $_.sdks } | Where-Object { $_.version -ceq $Version })
    if ($sdks.Count -lt 1) { throw "Exact SDK '$Version' is absent from Microsoft's channel metadata; no substitution is allowed." }
    return $sdks[0]
}

function Invoke-CsrunDocker([string[]] $Arguments) {
    & docker @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "docker $($Arguments[0]) failed with exit $LASTEXITCODE." }
}

function BuildAndPublish {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$SdkVersion,

        [string]$ImageName = 'csrun',

        [Alias('Registry')][string]$Repository = 'docker.io/codebeltnet/',

        [string]$Dockerfile = './csrun.Dockerfile',

        [ValidateSet('linux/amd64', 'linux/arm64')][string[]]$Platform,

        [hashtable]$DockerContext = @{},

        [hashtable]$Builder = @{},

        [switch]$BuildOnly,

        [string]$EnginePath,

        [string]$EngineVersion,

        [string]$EngineRepository = 'codebeltnet/csrun',

        [string]$SourceRepository = 'https://github.com/codebeltnet/csrun',

        [string]$ArchivePath = './artifacts/csrun.oci.tar',

        [string]$MetadataFile = './artifacts/csrun-image.json',

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    if (-not $Platform) {
        $Platform = if ($BuildOnly) { @('linux/' + [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant().Replace('x64', 'amd64')) } else { @('linux/amd64', 'linux/arm64') }
    }
    $resolvedVersions = @(foreach ($version in $SdkVersion) {
        Resolve-DotNetSdkTagSet -SdkVersion $version
    })

    Assert-UniqueResolvedTags -ResolvedVersion $resolvedVersions

    $majorTags = $resolvedVersions.MajorTag -join '-'
    $majorMinorTags = $resolvedVersions.MajorMinorTag -join '-'
    $publishTags = $resolvedVersions.PublishTag -join '-'
    foreach ($version in $resolvedVersions) {
        if ($version.FullVersion -cnotmatch '^(?:[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$' -or [version](($version.FullVersion -split '-')[0]) -lt [version]'10.0.0') { throw 'Supply exact .NET 10+ SDK versions.' }
    }
    $tags = @($publishTags, $majorMinorTags, $majorTags)
    if (@($tags | Where-Object { $_.Length -gt 128 -or $_ -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$' }).Count) { throw 'Invalid or overlong Docker tag.' }
    if ($BuildOnly -and $Platform.Count -ne 1) { throw 'BuildOnly loads one architecture at a time; test each explicitly.' }
    $image = '{0}/{1}' -f $Repository.TrimEnd('/'), $ImageName
    if (@($Platform | Select-Object -Unique).Count -ne $Platform.Count) { throw 'Supply each target platform only once.' }
    if ($EnginePath -and $EngineVersion -cnotmatch '^v\d+\.\d+\.\d+$') { throw 'Local engines require an explicit release version.' }
    if (-not $BuildOnly -and $image -ceq 'docker.io/codebeltnet/csrun') {
        if ($Platform.Count -ne 2) { throw 'Codebelt production requires both native AMD64 and ARM64 verification.' }
        if ($EnginePath -or $EngineRepository -cne 'codebeltnet/csrun' -or $SourceRepository -cne 'https://github.com/codebeltnet/csrun') { throw 'Codebelt production images require the canonical source and verified latest published engine.' }
    }

    $invocation = [pscustomobject]@{
        ImageName      = $ImageName
        Repository     = $Repository
        Dockerfile     = $Dockerfile
        SourceRepository = $SourceRepository
        SdkVersions    = @($resolvedVersions.FullVersion)
        MajorTags      = $majorTags
        MajorMinorTags = $majorMinorTags
        PublishTags    = $publishTags
        BuildArgs      = @()
        Tags           = @($tags | ForEach-Object { "${image}:$_" })
        Platforms      = $Platform
        DockerContexts = $DockerContext
        Builders       = $Builder
        EngineVersion  = $null
        EngineSha256   = $null
        BaseImage      = $null
        MetadataFile   = [IO.Path]::GetFullPath($MetadataFile)
        Published      = $false
        ImageId        = $null
        SizeBytes      = $null
        ConfigDigest   = $null
        OciArchiveBytes = $null
    }

    $targetImage = $invocation.Tags[0]

    $action = if ($BuildOnly) { 'Build and test local Docker image' } else { 'Build, natively test and publish Docker image' }
    if ($PSCmdlet.ShouldProcess($targetImage, $action)) {
        $dockerfilePath = (Resolve-Path -LiteralPath $Dockerfile).Path
        if (-not $BuildOnly) {
            $status = & git -C $PSScriptRoot status --porcelain
            if ($LASTEXITCODE -ne 0 -or $status) { throw 'Publication requires a clean, reviewed source commit. Use BuildOnly for worktree validation.' }
        }
        foreach ($architecture in $Platform) {
            $contextArgs = if ($DockerContext.ContainsKey($architecture)) { @('--context', [string]$DockerContext[$architecture]) } else { @() }
            $daemon = & docker @contextArgs info --format '{{.OSType}}/{{.Architecture}}'
            if ($LASTEXITCODE -ne 0) { throw "Cannot access native Docker host for $architecture. Configure -DockerContext and -Builder." }
            $normalized = $daemon.Trim().Replace('x86_64', 'amd64').Replace('aarch64', 'arm64')
            if ($normalized -cne $architecture) { throw "Native Docker host required for $architecture; got $normalized. Configure an explicit remote -DockerContext; emulation is insufficient." }
        }
        & python (Join-Path $PSScriptRoot 'tools/oci.py') check-skopeo
        if ($LASTEXITCODE -ne 0) { throw 'Skopeo transport prerequisites failed. Remote utility Docker daemons require native Skopeo on the client.' }
        $index = (Invoke-RestMethod 'https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json').'releases-index'
        $sdks = @($resolvedVersions | ForEach-Object { Get-CsrunSdkRelease $_.FullVersion $index })
        $base = $resolvedVersions | Sort-Object { [version](($_.FullVersion -split '-')[0]) } -Descending | Select-Object -First 1
        $available = (Invoke-RestMethod 'https://mcr.microsoft.com/v2/dotnet/sdk/tags/list').tags
        $baseTag = @('resolute', 'noble') | ForEach-Object { "$($base.PublishTag)-$_" } | Where-Object { $_ -cin $available } | Select-Object -First 1
        if (-not $baseTag) { throw "No verified Ubuntu SDK image for $($base.FullVersion)." }
        $baseImage = "mcr.microsoft.com/dotnet/sdk:$baseTag"
        $inspection = & docker buildx imagetools inspect $baseImage
        if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve base image digest.' }
        $digest = [regex]::Match(($inspection -join "`n"), '(?m)^Digest:\s+(sha256:[a-f0-9]{64})\s*$')
        if (-not $digest.Success) { throw 'Missing base image digest.' }
        $invocation.BaseImage = "$baseImage@$($digest.Groups[1].Value)"
        $context = Join-Path ([IO.Path]::GetTempPath()) ('csrun-image-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $context
        try {
            Copy-Item -LiteralPath $dockerfilePath -Destination (Join-Path $context 'csrun.Dockerfile')
            $dockerfilePath = Join-Path $context 'csrun.Dockerfile'
            $engine = Join-Path $context 'csrun.ps1'
            $engineUrl = "https://github.com/$EngineRepository/releases/latest/download/csrun.ps1"
            if ($EnginePath) {
                Copy-Item -LiteralPath $EnginePath -Destination $engine
                if ($SourceRepository -cne 'https://github.com/codebeltnet/csrun') { $engineUrl = 'file:csrun.ps1' }
                $release = @{tag_name=$EngineVersion}
                $hash = (Get-FileHash $engine -Algorithm SHA256).Hash.ToLowerInvariant()
            } else {
                # Resolve the moving reference once for all requested platforms.
                if ($EngineRepository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid engine repository.' }
                $release = Invoke-RestMethod "https://api.github.com/repos/$EngineRepository/releases/latest"
                $asset = @($release.assets | Where-Object name -CEQ 'csrun.ps1')
                if ($release.draft -or $release.tag_name -cnotmatch '^v\d+\.\d+\.\d+$' -or $asset.Count -ne 1 -or $asset[0].digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Latest release has no verifiable csrun.ps1 asset.' }
                Invoke-WebRequest $engineUrl -OutFile $engine
                $hash = (Get-FileHash $engine -Algorithm SHA256).Hash.ToLowerInvariant()
                if ("sha256:$hash" -cne $asset[0].digest -or (Get-Item $engine).Length -ne $asset[0].size) { throw 'Latest engine asset changed or failed integrity validation.' }
            }
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($engine, [ref]$tokens, [ref]$errors)
            if ($errors.Count -or -not $ast.ParamBlock -or 'ManifestJson' -notin $ast.ParamBlock.Parameters.Name.VariablePath.UserPath) { throw 'Downloaded engine is not a valid manifest-capable PowerShell script.' }
            $invocation.EngineVersion = $release.tag_name
            $invocation.EngineSha256 = $hash
            foreach ($file in @('container-entrypoint.ps1', 'container-build.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $context }
            $revision = & git -C $PSScriptRoot rev-parse HEAD
            if ($LASTEXITCODE -ne 0) { throw 'Unable to identify packaging source commit.' }
            $extra = @($sdks | Where-Object version -CNE $base.FullVersion | ForEach-Object { @{version=$_.version; files=@($_.files | Where-Object { $_.rid -in @('linux-x64', 'linux-arm64') -and $_.url.EndsWith('.tar.gz') })} })
            $buildArgs = @('--build-arg', "BASE_IMAGE=$($invocation.BaseImage)", '--build-arg', "SDK_ARTIFACTS_JSON=$(ConvertTo-Json -InputObject $extra -Depth 8 -Compress)", '--build-arg', "ENGINE_VERSION=$($invocation.EngineVersion)", '--build-arg', "ENGINE_SHA256=$hash", '--build-arg', "ENGINE_URL=$engineUrl", '--label', "org.opencontainers.image.version=$($invocation.EngineVersion)", '--label', "org.opencontainers.image.source=$SourceRepository", '--label', "org.opencontainers.image.revision=$revision")
            $invocation.BuildArgs = @($buildArgs[1], $buildArgs[3], $buildArgs[5], $buildArgs[7])
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $invocation.MetadataFile)
            $archiveRoot = [IO.Path]::GetFullPath($ArchivePath)
            $archives = @()
            $verification = @()
            foreach ($architecture in $Platform) {
                $cpu = ($architecture -split '/')[1]
                $contextArgs = if ($DockerContext.ContainsKey($architecture)) { @('--context', [string]$DockerContext[$architecture]) } else { @() }
                $builderArgs = if ($Builder.ContainsKey($architecture)) { @('--builder', [string]$Builder[$architecture]) } else { @() }
                $archive = "$archiveRoot.$cpu.tar"
                $null = New-Item -ItemType Directory -Force -Path (Split-Path $archive)
                $created = [DateTime]::UtcNow.ToString('o')
                Invoke-CsrunDocker ($contextArgs + @('buildx', 'build') + $builderArgs + @('--output', "type=oci,name=$targetImage,dest=$archive", '--sbom=true', '--provenance=mode=max', '--platform', $architecture, '--file', $dockerfilePath, '--label', "org.opencontainers.image.created=$created", '--label', "net.codebelt.csrun.sdks=$($resolvedVersions.FullVersion -join ',')") + $buildArgs + @($context))
                & python (Join-Path $PSScriptRoot 'tools/oci.py') verify $archive --version $release.tag_name --revision $revision --engine $hash --source $SourceRepository --platform $cpu
                if ($LASTEXITCODE -ne 0) { throw 'OCI verification failed.' }
                $localImage = 'csrun-verify:' + $cpu + '-' + [guid]::NewGuid().ToString('N')
                $loadArchive = Join-Path $context "image-$cpu.docker.tar"
                if (Get-Command skopeo -ErrorAction SilentlyContinue) {
                    & skopeo copy --override-os linux --override-arch $cpu "oci-archive:$archive" "docker-archive:${loadArchive}:$localImage"
                    if ($LASTEXITCODE -ne 0) { throw 'Cannot load the exported OCI artifact for native testing.' }
                } else {
                    Invoke-CsrunDocker @('run', '--rm', '--user', '0', '--volume', "$(Split-Path $archive):/oci:ro", '--volume', "${context}:/converted", 'quay.io/skopeo/stable:v1.20.0', 'copy', '--override-os', 'linux', '--override-arch', $cpu, "oci-archive:/oci/$(Split-Path $archive -Leaf)", "docker-archive:/converted/$(Split-Path $loadArchive -Leaf):$localImage")
                }
                Invoke-CsrunDocker ($contextArgs + @('load', '--input', $loadArchive))
                Remove-Item -LiteralPath $loadArchive -Force
                & (Join-Path $PSScriptRoot 'tests/container.Tests.ps1') -Image $localImage -SdkVersion $resolvedVersions.FullVersion -Platform $architecture -EngineSha256 $hash -EngineUrl $engineUrl -RequireNative -DockerContext $(if ($DockerContext.ContainsKey($architecture)) { [string]$DockerContext[$architecture] } else { '' })
                if ($LASTEXITCODE -ne 0) { throw "Container tests failed on $architecture." }
                $details = @(& docker @contextArgs image inspect $localImage | ConvertFrom-Json)[0]
                if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect tested image.' }
                $verifyContextArgs = if ($DockerContext.ContainsKey($architecture)) { @('--context', [string]$DockerContext[$architecture]) } else { @() }
                $configDigest = & python (Join-Path $PSScriptRoot 'tools/oci.py') loaded-config $archive --platform $cpu --image $localImage @verifyContextArgs
                if ($LASTEXITCODE -ne 0) { throw 'Loaded image differs from exported OCI artifact.' }
                $invocation.ConfigDigest = $configDigest
                $invocation.ImageId = $details.Id
                $invocation.SizeBytes = $details.Size
                $invocation.OciArchiveBytes = (Get-Item -LiteralPath $archive).Length
                $archives += $archive
                $verification += [pscustomobject]@{Platform=$architecture; ImageId=$details.Id; ConfigDigest=$configDigest; SizeBytes=$details.Size; NativeVerified=$true}
            }
            $invocation | Add-Member Verification $verification
            $invocation | Add-Member ArchivePaths $archives
            $invocation | Add-Member SourceCommit $revision
            $invocation | Add-Member NativeVerified $true
            $invocation | ConvertTo-Json -Depth 8 | Set-Content $invocation.MetadataFile
            if ($BuildOnly) {
                foreach ($tag in $invocation.Tags) { Invoke-CsrunDocker ($contextArgs + @('tag', $localImage, $tag)) }
            } else {
                if (-not $EnginePath) {
                    $currentRelease = Invoke-RestMethod "https://api.github.com/repos/$EngineRepository/releases/latest"
                    if ($currentRelease.id -ne $release.id) { throw 'Latest engine release changed during native verification; refusing stale alias publication.' }
                }
                $platformArgs = if ($Platform.Count -eq 1) { @('--platform', ($Platform[0] -split '/')[1]) } else { @() }
                & python (Join-Path $PSScriptRoot 'tools/oci.py') merge $archiveRoot --version $release.tag_name --revision $revision --engine $hash --source $SourceRepository @platformArgs @archives
                if ($LASTEXITCODE -ne 0) { throw 'Cannot assemble native-verified artifacts.' }
                & python (Join-Path $PSScriptRoot 'tools/oci.py') publish $archiveRoot --version $release.tag_name --revision $revision --engine $hash --source $SourceRepository @platformArgs --tags @($invocation.Tags)
                if ($LASTEXITCODE -ne 0) { throw 'Registry promotion or inspection failed.' }
                $invocation.Published = $true
                $invocation | Add-Member RegistryImages (Get-Content "$archiveRoot.published.json" -Raw | ConvertFrom-Json)
                $invocation | ConvertTo-Json -Depth 10 | Set-Content $invocation.MetadataFile
            }
        } finally {
            # Only remove the exact temporary context created by this invocation.
            if ([IO.Path]::GetDirectoryName($context) -cne [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar) -or [IO.Path]::GetFileName($context) -cnotmatch '^csrun-image-[a-f0-9]{32}$') { throw 'Unsafe build context cleanup path.' }
            Remove-Item -LiteralPath $context -Recurse -Force
        }
    }

    if ($PassThru) {
        return $invocation
    }
}

Export-ModuleMember -Function BuildAndPublish
