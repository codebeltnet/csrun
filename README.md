# csrun

Run a complete C# console example or genuine xUnit v3 tests with one command. Choose native PowerShell execution or a disposable Linux container; both consume manifest schema version 1 through the same csrun engine.

Native execution requires PowerShell 7 and an installed .NET 10+ SDK with support for file-based applications and the requested target framework/runtime. Container execution requires Docker with Linux containers, and supplies PowerShell and the explicitly selected SDKs inside the image. Docker Desktop on Windows works from PowerShell 7 without installing .NET on the host. Network access is required for Microsoft's release metadata and uncached NuGet dependencies. The runner never installs SDKs or retargets source.

## Copy & Run

```powershell
& ([scriptblock]::Create((irm 'https://github.com/codebeltnet/csrun/releases/latest/download/csrun.ps1'))) -Source 'Console.WriteLine(42);'
$LASTEXITCODE
```

For longer source, use an inline JSON here-string in the same invocation:

```powershell
& ([scriptblock]::Create((irm 'https://github.com/codebeltnet/csrun/releases/latest/download/csrun.ps1'))) -ManifestJson @'
{
  "schemaVersion": 1,
  "mode": "console",
  "framework": "net11.0",
  "dependsOn": ["Cuemon.Kernel@11.0.0"],
  "source": "using System; using Cuemon; Console.WriteLine(new DateSpan(new DateTime(2018, 1, 1), new DateTime(2018, 10, 1)).TotalDays);"
}
'@
```

Executing remote code requires trusting **both the script publisher and the C# source**, including NuGet packages and their build assets. Everything runs with your current permissions. This is not a sandbox. Review the script before execution when appropriate. No other scripts are downloaded or executed by csrun. The scriptblock invocation supports parameters; `irm ... | iex` alone does not provide that interface.

## Disposable container execution

After the maintainer publishes the Docker images, pipe the same manifest directly to Docker. No clipboard operation, file, clone, volume mount, or profile customization is needed:

The examples use PowerShell syntax; any shell that can write UTF-8 JSON to Docker's stdin can use the container path without host PowerShell.

```powershell
'{"schemaVersion":1,"mode":"console","framework":"net10.0","source":"Console.WriteLine(42);"}' | docker run --rm -i codebeltnet/csrun:10
$LASTEXITCODE # 0; C# prints 42

'{"schemaVersion":1,"mode":"test","framework":"net10.0","source":"using Xunit; public class SmokeTest { [Fact] public void Pass() => Assert.True(true); }"}' | docker run --rm -i codebeltnet/csrun:10
$LASTEXITCODE # 0; one discovered, passing test
```

Use `-i` for stdin; a TTY (`-t`) is unnecessary. The entry point reads the complete UTF-8 JSON document, delegates to the bundled engine, streams its output, and preserves its exit status. Compilation failures are nonzero, failing assertions return MTP exit `2`, and no discovered tests return `8`.

Docker pulls a missing image on the first invocation and subsequently reuses its local image cache. Use `docker pull codebeltnet/csrun:10` to explicitly update it. This does **not** create a persistent NuGet cache: each new container may restore packages again. Generated source, projects, package caches and build artifacts remain inside container-owned storage and disappear with `--rm`. No host directories, Docker socket, host credentials or host environment are passed automatically.

SDK tags identify environments, not csrun versions. `:10` contains only its explicitly built .NET 10 SDK and associated runtimes; `:11` contains only .NET 11; `:10-11` contains both. Always specify a compatible manifest framework when using a single-SDK image. In particular, while .NET 10 is the highest supported GA LTS, an omitted framework selects `net10.0` even in `:11`, where it fails because the runtime is absent. The adapter never substitutes `net11.0`. A combined image normally selects the newest installed SDK and can execute either supported TFM with its installed runtime.

Production Codebelt images bundle the verified [latest published release asset](https://github.com/codebeltnet/csrun/releases/latest/download/csrun.ps1). Release preparation builds with the candidate script; deployment resolves the published asset once and requires its release identity and checksum to match the tested image. The standalone manual builder resolves the latest asset once for all architectures by default; forks can supply their own engine. The image contains the script and never downloads it at startup. The csrun release version, explicit SDK versions and manifest schema version remain independent.

All SDK tags are mutable. An already cached image stays unchanged until pulled or removed. Use a published digest when an immutable identity is required: `docker run --rm -i codebeltnet/csrun@sha256:<published-digest>`. Inspect the engine identity and packaging revision with:

```powershell
docker image inspect codebeltnet/csrun:10 --format '{{json .Config.Labels}}'
docker buildx imagetools inspect codebeltnet/csrun:10
docker run --rm --entrypoint dotnet codebeltnet/csrun:10 --list-sdks
docker run --rm --entrypoint dotnet codebeltnet/csrun:10 --list-runtimes
```

The `net.codebelt.csrun.engine.release` and `net.codebelt.csrun.engine.sha256` labels identify the exact bundled asset. OCI `version` identifies that engine release; OCI `revision` identifies the packaging source commit. Published Buildx metadata records the registry digest; retain it with release notes for immutable consumers.

### Isolation and writable paths

The default user is Microsoft's unprivileged `app` user. The image uses `/tmp` for its working directory, home, PowerShell configuration, .NET user state, NuGet caches and temporary builds. A hardened invocation supplies executable writable temporary storage while protecting the root filesystem:

```powershell
'{"schemaVersion":1,"mode":"console","framework":"net10.0","source":"Console.WriteLine(42);"}' | docker run --rm -i --read-only --tmpfs /tmp:rw,exec,nosuid,nodev,size=1g,mode=1777 --cap-drop=ALL --security-opt=no-new-privileges --cpus=2 --memory=2g --pids-limit=256 codebeltnet/csrun:10
$LASTEXITCODE
```

The integration suite verifies console and genuine xUnit execution with these restrictions. Do not add `noexec` to build-artifact storage: compiled applications and tests must execute there. Adjust the limits for larger samples. Network remains enabled for metadata and NuGet.

Docker provides meaningful isolation, but **does not guarantee safe execution of arbitrary hostile code**. Docker permissions, vulnerabilities, outbound network access and resource exhaustion still matter. This is not a secure public code-execution sandbox. Do not add privileged mode, host namespaces, Docker socket mounts, host credential forwarding or unnecessary host mounts.

## Local native use

```powershell
# Canonical manifest input
./csrun.ps1 -ManifestJson (Get-Content ./samples/datespan.json -Raw)

# Explicit local options (PowerShell array syntax for multiple packages)
./csrun.ps1 -Mode console -Framework net11.0 -DependsOn Cuemon.Kernel@11.0.0 -File ./tests/fixtures/DateSpan.cs
./csrun.ps1 -Source 'System.Console.WriteLine("hello");'

# Clipboard-first exploration: copy complete runnable C# first
./csrun.ps1
./csrun.ps1 -Clipboard -Mode console -Framework net11.0

# Genuine xUnit v3 / Microsoft.Testing.Platform execution
./csrun.ps1 -Mode test -File ./tests/fixtures/OutputLinesTest.cs -DependsOn Codebelt.Extensions.Xunit@13.0.0,xunit.v3@4.0.3
./csrun.ps1 -ManifestJson (Get-Content ./samples/output-lines.json -Raw)

Get-Help ./csrun.ps1 -Detailed
```

Direct options default to `console`, the latest supported GA LTS framework, and no packages. [The LTS sample](samples/default-lts.json) omits the framework. Source defaults to `Get-Clipboard -Raw` when available; an empty/unavailable clipboard produces an error. `-Source`, `-File`, and `-Clipboard` are mutually exclusive. `-ManifestJson` excludes all direct configuration and input options. Both paths use the same validation and execution implementation. Invoke from PowerShell when passing package arrays; native `pwsh -File` does not bind comma-separated strings as arrays.

## Manifest version 1

| Field | Contract |
| --- | --- |
| `schemaVersion` | Required integer `1`. |
| `mode` | Required `console` or `test`, case-insensitive. |
| `framework` | Optional .NET 10+ TFM such as `net11.0` or `net11.0-windows`. Omission selects the highest supported GA LTS channel; an explicit value is preserved and must identify a supported GA LTS or STS channel or the latest preview/go-live channel. RIDs such as `win-x64` are invalid. Platform availability is checked by the SDK. |
| `source` | Required nonempty string containing a complete program or test source. Multiline text, quotes, Unicode, and line endings are preserved. |
| `dependsOn` | Optional array of `PackageId@ExactVersion` pins, including prereleases. Identical duplicates collapse; conflicting versions, ranges, wildcards, and unversioned packages fail. Use three or four numeric version components. |
| `sdk` | Optional `Microsoft.NET.Sdk` (default) or `Microsoft.NET.Sdk.Web`. Never inferred. |
| `frameworkReferences` | Optional array of framework reference names. Test projects emit explicit, XML-escaped references. For console applications, only `Microsoft.AspNetCore.App` with explicitly selected `Microsoft.NET.Sdk.Web` is supported, through the SDK's implicit reference. Other console references fail with a diagnostic. |

Unknown fields are rejected to expose misspellings. No package discovery, source wrapping, method mode, or source rewriting occurs. Ordinary transitive NuGet dependencies still resolve normally. Source-only methods without a runnable entry point produce the actual compiler error.

Both modes validate the target against Microsoft's [release index](https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json), cached for up to 12 hours. If the index and a recent valid cache are unavailable, execution fails. An explicit preview target is the opt-in; no automatic fallback occurs when the default LTS cannot run. The selected SDK follows `global.json`, must be .NET 10 or newer, and must support the target. A newer SDK can build an older supported target. The corresponding .NET runtime and any required ASP.NET shared framework must be installed; csrun installs neither. Platform-specific build requirements are checked by the SDK.

Console mode prepends SDK, target framework, and pinned package directives to the source stream and invokes `dotnet run -`. If a current-directory project exists, SDK 11 would select it first; csrun instead uses an isolated temporary `.cs` file and `dotnet run --file` to force file-based execution while retaining the program's working directory. It creates no console project. The SDK manages its own normal build cache. Approximate NuGet matches and downgrades are errors, preventing an unavailable pin from silently becoming another version.

Existing source directives must be in the leading preamble (blank lines, leading comments, and C# preprocessor directives such as `#nullable` are permitted). Only matching SDK, target framework, and manifest package directives are supported. Matching directives remain in the original source and are not emitted again. Multiple occurrences of the same source setting fail explicitly because the SDK rejects duplicate directives. Conflicts and other preamble directives also fail explicitly. Build customization outside this contract belongs in a future schema, not arbitrary MSBuild directives.

Test mode writes the original source to a minimal executable project in a unique temporary directory and runs `dotnet run --project ... -- --show-live-output on --progress off --no-banner`. It uses **xunit.v3@4.0.3** by default, with `UseMicrosoftTestingPlatformRunner=true`. Explicit stable xunit.v3 **4.0 patch versions >= 4.0.3** are accepted as the supported MTP v2 compatibility band; other engine variants and incompatible versions are rejected. User packages are added as exact NuGet references. The project is removed in `finally` after successful runs, compilation/restore errors, or failed tests. Forced process termination cannot guarantee cleanup.

The Codebelt example discovers one passing test and displays `started`, `2`, and `finished` through live `ITestOutputHelper` output. Its `HasTestOutput` assertion only checks that an output helper exists; the integration suite separately verifies the three visible lines. Facts, theories, async tests, constructor injection, fixture disposal, and skipped tests run through the actual xUnit engine. Failed assertions return MTP exit **2**; an empty assembly returns **8**. csrun preserves child stdout/stderr and exit status; validation and prerequisite failures return **1**. `$LASTEXITCODE` is available after local invocation; `pwsh -File ./csrun.ps1 ...` propagates it to the shell. Scriptblock invocation leaves the calling session alive and sets `$LASTEXITCODE`.

Pinned package/TFM execution is distinct from downloading the latest script release. Complete reproduction also depends on the installed SDK/runtime, NuGet configuration and transitive dependencies, platform, and any external services used by the program. Test projects live outside the caller's directory and do not depend on its `dotnet test` runner selection; the selected `dotnet` SDK still respects applicable `global.json` selection. There is no implicit runtime roll-forward or SDK installation.

## Build and publish SDK environments

The self-contained module requires PowerShell 7, Git and Docker with Buildx. It uses native Docker CLI argument arrays and requires no personal PowerShell modules. Run from the repository root. These commands deliberately **build, test and publish** to Docker Hub; run them only after publication approval and `docker login docker.io`:

```powershell
Import-Module .\BuildAndPublish.psm1 -Force

BuildAndPublish 10.0.404
BuildAndPublish 11.0.100
BuildAndPublish 10.0.404 11.0.100
```

| Exact SDK inputs | Published SDK environment tags |
| --- | --- |
| `10.0.404` | `10.0.404`, `10.0`, `10` |
| `11.0.100` | `11.0.100`, `11.0`, `11` |
| `10.0.404 11.0.100` | `10.0.404-11.0.100`, `10.0-11.0`, `10-11` |

No additional aliases are generated. Input order determines tag order. Full prerelease SDK versions remain exact installation inputs; release-build suffixes normalize for image tags using the Ubuntu Test Runner convention (for example, `11.0.100-rc.1.26425.128` becomes `11.0.100-rc.1`). Duplicate major, major.minor or normalized publish tags are rejected before Docker runs. Only supported .NET 10+ GA channels and the latest explicitly requested preview/go-live channel are accepted. Exact SDK availability is checked in Microsoft's per-channel release metadata, not inferred from the release index's latest patch.

```powershell
# Plan only: no downloads, build, tests, or publication
BuildAndPublish 10.0.404 11.0.100 -WhatIf -PassThru

# Local build and full container validation, with no registry writes
BuildAndPublish 10.0.404 -BuildOnly -PassThru -MetadataFile ./artifacts/10.json

# Optional names/paths; Registry is an alias for the reference module's Repository
BuildAndPublish 10.0.404 -ImageName csrun -Registry docker.io/codebeltnet/ -Dockerfile ./csrun.Dockerfile -WhatIf
```

`-WhatIf -PassThru` reports SDK aliases without network access or side effects. `-BuildOnly` exports an OCI archive with BuildKit SBOM and provenance, loads that exact artifact for the native container suite, and records its config identity, size, SDK inventory and engine checksum. Use separate `-ArchivePath` and `-MetadataFile` paths when retaining several builds. Build-only defaults to the host CPU; specify a supported platform explicitly when using a remote native host. Cross-architecture execution fails rather than substituting emulation.

The positional publishing commands build independently with local Docker/Buildx or explicitly configured remote builders. They do not call GitHub Actions, read CI-produced artifacts, use Codebelt credentials, or require the GitHub CLI. Publication defaults to both architectures; both native Docker hosts must be reachable before construction starts. A machine with only AMD64 support fails clearly for ARM64. To publish a deliberately single-architecture fork image, explicitly pass `-Platform linux/amd64`; this does not claim ARM64 support. `-BuildOnly` defaults to the host CPU and performs no registry writes.

```powershell
# Configure ordinary Docker contexts/builders once for your own native hosts.
# Both named contexts below must already exist and point to the indicated CPUs.
$contexts = @{ 'linux/amd64' = 'native-amd64'; 'linux/arm64' = 'native-arm64' }
$builders = @{ 'linux/amd64' = 'builder-amd64'; 'linux/arm64' = 'builder-arm64' }
BuildAndPublish 10.0.404 11.0.100 -DockerContext $contexts -Builder $builders `
    -Registry docker.io/my-account/ -ImageName csrun

# A fork can package its own reviewed engine without any Codebelt release asset.
BuildAndPublish 11.0.100 -DockerContext $contexts -Builder $builders `
    -Registry docker.io/my-account/ -EnginePath ./csrun.ps1 -EngineVersion v0.2.0 `
    -SourceRepository https://github.com/my-account/csrun
```

Local builds need PowerShell 7, Python 3.11+ (standard library only), Docker and an OCI-capable Buildx `docker-container` builder. Select a builder deliberately with `docker buildx create --name csrun-builder --driver docker-container --use`, set `BUILDX_BUILDER`, or supply the architecture-to-builder map above. `-DockerContext` selects each **runtime test host**, which must report the corresponding native CPU. A Buildx platform declaration alone never substitutes for this runtime check. Builds export once; native tests consume those exact exports; publishing merges and promotes the tested manifests without rebuilding.

Skopeo performs OCI transport, either installed locally or in a versioned utility container launched through Docker. Its temporary Docker-format conversion for `docker load` preserves the original config and filesystem identities. Python checks the raw config exported by the test daemon; Docker's displayed image ID may instead be a manifest digest on containerd-backed installations. No utility socket or credentials enter the csrun product image. Publishing requires authentication to your chosen registry: use native `skopeo login` or supply `REGISTRY_AUTH_FILE` containing a scoped registry auth configuration for the utility container. Credentials never become build arguments or release artifacts. A clean reviewed checkout is required for publication. `-PassThru` returns the invocation, engine identity, native results, sizes and final registry digests.

The default engine source remains the verified canonical latest Codebelt GitHub Release asset, resolved once per invocation. A fork can select `-EngineRepository owner/repository` for its own latest published engine, or explicitly supply its local engine with `-EnginePath` and `-EngineVersion`. Local-engine publication is refused for the default Codebelt production repository. `-SourceRepository` sets the fork's source identity label. No CI artifacts are involved in manual builds.

The newest requested SDK supplies the official Ubuntu base (verified Resolute or Noble tag, pinned to a digest). Its SDK and PowerShell are retained. Additional SDK archives come from Microsoft's exact release metadata, are checked against SHA-512, and install side by side without overwriting existing host files, runtimes or packs. Both NETCore and ASP.NET Core runtimes and the official image's Git remain available. No debugger or unrelated development packages are added.

Single-SDK images minimize download and local storage for one environment. Combined images add the explicitly requested SDK, runtimes and targeting packs, offering both TFMs at a larger size. See [container validation results](docs/container-validation.md) for measured local sizes and validation limits.

## Validation and releases

Run the dependency-free regression and integration suite:

```powershell
pwsh -NoProfile -File ./tests/csrun.Tests.ps1

# Pin the SDK, even when newer SDKs are also installed
pwsh -NoProfile -File ./tests/csrun.Tests.ps1 -SdkVersion 11.0.100
pwsh -NoProfile -File ./tests/csrun.Tests.ps1 -CompatibilityOnly -SdkVersion 10.0.115

# Publishing contract checks; no Docker or network required
pwsh -NoProfile -File ./tests/BuildAndPublish.Tests.ps1
python ./tests/oci.Tests.py

# Build and execute Docker integration tests without publishing
Import-Module ./BuildAndPublish.psm1 -Force
BuildAndPublish 10.0.404 -BuildOnly
BuildAndPublish 11.0.100 -BuildOnly
BuildAndPublish 10.0.404 11.0.100 -BuildOnly
```

Native tests invoke the actual standalone script in child processes, including local scriptblock invocation. Fixtures preserve the supplied full DateSpan and Codebelt xUnit examples. DateSpan with Cuemon.Kernel 11.0.0 prints `0 years`, `9 months`, **`40 weeks`**, `273 days`, `6552 hours`, `393,120 minutes`, and `23,587,200 seconds`. Native regression tests remain on Windows; Docker integration tests execute the candidate engine in PR/release preparation and verify it against the published engine before promotion. Native macOS remains unverified.

Both workflows test .NET 11 and .NET 10 channel compatibility using the highest installed GA SDK in each channel after Codebelt SDK setup. The harness writes an isolated `global.json` with roll-forward disabled and verifies that exact selected SDK for each run. CI does not guarantee coverage of the older SDK versions shown in the local commands above or establish minimum SDK version compatibility. The compatibility run targets `net10.0` and covers console stdin, forced file execution beside an existing project, and real MTP success, failure, empty discovery, compilation failure, and restore failure.

Both suites include runs with normal compiler/MSBuild server settings, checking exit codes and removal of csrun's own disposable artifacts. These runs retain the normal host temp location for SDK-managed compiler caches; they neither delete those caches nor shut down unrelated servers. The remaining tests disable server reuse to keep their isolated harness directory disposable. Assertions remove ANSI colors and terminal hyperlinks; raw stdout/stderr remain available for diagnostics. A regression forces MTP's real ANSI formatter and still requires all three Codebelt output lines. The standalone runner preserves the original child output.

PR and tagged-release validation build the checked-out **candidate** engine. Windows regression jobs use `windows-2025`. Every Linux job uses a fixed Ubuntu 26.04 label; actual container execution uses `ubuntu-26.04` for AMD64 and `ubuntu-26.04-arm` for ARM64. Each CPU runs all three SDK variants and checks image/daemon/runtime architecture, PowerShell startup, SDK/runtime inventories, real console compilation and xUnit discovery/pass/failure, pinned Codebelt packages, disposal and hardened execution. Set branch protection to require **Required quality gate**; it rejects failed, cancelled or skipped dependencies. Native ARM64 remains unverified until GitHub-hosted CI actually runs.

Release delivery follows these stages:

1. After approval to tag and push, `release.yml` independently runs Windows and six native container jobs. Each job exports once with SBOM and maximum BuildKit provenance, verifies the archive graph and attestation subjects, imports that artifact for testing, and compares the loaded config digest with the OCI config. No registry credentials are available.
2. Assembly combines the unchanged AMD64/ARM64 manifests and attestations into one index per SDK environment. `codebeltnet/oci-artifact-verify@v1` checks the checksum, released source identity and multi-platform contract; csrun also validates all blobs, config labels, native result records, SBOM and provenance. No layers are rebuilt.
3. The established release job creates a **draft GitHub Release** containing the tested standalone engine, its checksum, release records and tested OCI artifacts. Archives are split into 1 GiB assets to stay below GitHub's per-file limit. Large Actions artifacts have one-day retention and are deleted after successful durable release attachment; deployment recovery uses GitHub Release assets. PR jobs upload small JSON records rather than image archives. Expect several GiB of temporary release-run storage across six native builds and assembly; assembly is divided by SDK variant to limit runner disk use. The draft-creation job alone has Actions write permission to delete these transient copies.
4. After review and explicit approval, publish the draft as the latest GitHub Release. `deploy.yml` resolves `releases/latest/download/csrun.ps1` **once**, verifies GitHub's asset digest/size and release ID, and requires that release to match the deployment request. It verifies tag ancestry on main, the successful authoritative tag release run, both native results and the saved image engine checksum. Consequently the image built before publication must contain byte-identical released engine content. No build occurs after publication or during deployment.
5. The separate `Production` environment job promotes the existing OCI index to `docker.io/codebeltnet/csrun`, preserving all platform and attestation manifests. SDK patch, major.minor and major aliases reference the same content. There is **no Docker `latest` tag**, JCR or GHCR destination. Promotion fails if Skopeo cannot preserve child digests. CD inspects each registry index, downloads the published content by immutable digest, and validates its platforms, blobs, SBOM and provenance again. Workflow summaries contain tags, final index digest, both native results, exact SDK inventories, sizes, GitHub Release, source commit and engine checksum.

Configure the `Production` GitHub environment with required reviewers and restricted deployment refs **before enabling publication**. Store a Docker Hub account name in `DOCKERHUB_USERNAME` and a repository-scoped access token in `DOCKERHUB_TOKEN` as environment secrets. Only the publishing step receives these secrets; authentication uses stdin and a temporary auth file removed on exit. PRs, release preparation and artifact verification never receive Docker Hub credentials. Repository environment protection and branch required checks are administrator settings; adding workflow YAML does not configure them.

For recovery, dispatch `deploy.yml` from `main` with the already-published latest release tag. It reuses the original release assets and successful native results, revalidates checksums, and never replaces missing content with a rebuild. Partial tag uploads can be retried idempotently against the same bytes. A release that is no longer latest is refused. New SDK patch versions require a reviewed release preparation run and newly verified artifacts; existing release recovery cannot silently change SDK versions.

The DocFX-specific builder is unsuitable for csrun execution. The generic Codebelt verifier is reused after assembly. The generic publisher currently assumes one product SemVer tag, so the small `tools/oci.py` promotion path implements SDK aliases and post-push content verification. OCI verification, assembly and promotion are shared by CD and the independent manual module; release lifecycle orchestration belongs only to CI/CD. All action references use floating version tags. The Python OCI utilities use only the standard library.

The release/deploy separation follows [Cuemon's release workflow](https://github.com/codebeltnet/cuemon/blob/main/.github/workflows/release.yml) and [deployment workflow](https://github.com/codebeltnet/cuemon/blob/main/.github/workflows/deploy.yml). Runner labels follow the [GitHub-hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). Attestation validation follows [BuildKit's image attestation storage format](https://docs.docker.com/build/metadata/attestations/attestation-storage/); it verifies SBOM contents, manifest subjects and provenance build identities, without adding a separate signing authority.

GitHub-hosted execution, native ARM64 results and real Docker Hub publication still require an approved push and run. SBOM/provenance checks in the implementation are not evidence of a successful registry publication. See [container validation results](docs/container-validation.md) for measured local results and remaining limits.

Implementation references: [.NET file-based applications](https://learn.microsoft.com/en-us/dotnet/core/sdk/file-based-apps), [SDK stdin design and project precedence](https://github.com/dotnet/sdk/blob/main/documentation/general/dotnet-run-file.md), [xUnit MTP configuration](https://xunit.net/docs/getting-started/v3/microsoft-testing-platform), and [MTP exit codes](https://learn.microsoft.com/en-us/dotnet/core/testing/microsoft-testing-platform-exit-codes).
