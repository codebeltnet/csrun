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

The image build obtains the engine only from [the latest published release asset](https://github.com/codebeltnet/csrun/releases/latest/download/csrun.ps1), once per build/publication operation. It validates GitHub's asset checksum, size and PowerShell syntax, then uses that same asset for all requested architectures. The image contains the script, not a startup downloader. The csrun release version, explicit SDK versions and manifest schema version remain independent. Rebuilding after a newer csrun release requires no version-specific URL edits.

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

`-PassThru` returns the invocation and, after an actual successful operation, the engine release/checksum and pinned base image. Build-only metadata also records the image ID and size. `-WhatIf` reports unverified plans without resolving external state. Publication requires a clean source checkout, runs the complete container suite on each requested architecture, then publishes with Buildx SBOM and maximum provenance attestations. The build context snapshots the resolved engine, adapter, installer and Dockerfile; the same context and immutable base are used throughout the operation. There is no registry login or credential handling in PR validation.

Publication needs an attestation-capable Buildx builder. If the current builder lacks this capability, create one deliberately with `docker buildx create --name csrun-builder --driver docker-container --use` and `docker buildx inspect --bootstrap`. The module defaults to `linux/amd64`. `-Platform linux/amd64,linux/arm64` requires both platforms to execute locally or on configured native Buildx workers; it tests each before publishing. Local ARM64 validation currently fails with `exec format error` because this Docker Desktop host has no working ARM64 execution support. Native ARM64 Ubuntu CI validation is configured but remains unverified until the workflow runs. Do not advertise multi-architecture support until that validation passes.

The newest requested SDK supplies the official Ubuntu base (verified Noble or Resolute tag, resolved to a digest). Its existing SDK and PowerShell are retained. Additional SDK archives come from Microsoft's release metadata, are checked against SHA-512, and install side by side without overwriting existing host files, runtimes or packs. Both NETCore and ASP.NET Core runtimes are retained; SDK directories stay root-owned. Git from the official image is retained because a real MinVer build test demonstrates that removing it changes the generated version from the repository tag to a fallback. No debugger or unrelated development tools are added.

Use the module to build `csrun.Dockerfile`: it prepares the verified latest-release asset and checksum arguments; building directly from the checkout's engine is not the distribution path. Publishing metadata defaults to `artifacts/csrun-image.json` and includes `containerimage.digest`; save a separate `-MetadataFile` for each environment. Inspect the registry with `docker buildx imagetools inspect codebeltnet/csrun:10` after publication, and attach the metadata/digests to the release notes.

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

# Build and execute Docker integration tests without publishing
Import-Module ./BuildAndPublish.psm1 -Force
BuildAndPublish 10.0.404 -BuildOnly
BuildAndPublish 11.0.100 -BuildOnly
BuildAndPublish 10.0.404 11.0.100 -BuildOnly
```

Native tests invoke the actual standalone script in child processes, including local scriptblock invocation. Fixtures preserve the supplied full DateSpan and Codebelt xUnit examples. DateSpan with Cuemon.Kernel 11.0.0 prints `0 years`, `9 months`, **`40 weeks`**, `273 days`, `6552 hours`, `393,120 minutes`, and `23,587,200 seconds`. Native regression tests remain on Windows; Docker integration tests execute the released engine in Ubuntu Linux containers. Native macOS remains unverified.

Both workflows test .NET 11 and .NET 10 channel compatibility using the highest installed GA SDK in each channel after Codebelt SDK setup. The harness writes an isolated `global.json` with roll-forward disabled and verifies that exact selected SDK for each run. CI does not guarantee coverage of the older SDK versions shown in the local commands above or establish minimum SDK version compatibility. The compatibility run targets `net10.0` and covers console stdin, forced file execution beside an existing project, and real MTP success, failure, empty discovery, compilation failure, and restore failure.

Both suites include runs with normal compiler/MSBuild server settings, checking exit codes and removal of csrun's own disposable artifacts. These runs retain the normal host temp location for SDK-managed compiler caches; they neither delete those caches nor shut down unrelated servers. The remaining tests disable server reuse to keep their isolated harness directory disposable. Assertions remove ANSI colors and terminal hyperlinks; raw stdout/stderr remain available for diagnostics. A regression forces MTP's real ANSI formatter and still requires all three Codebelt output lines. The standalone runner preserves the original child output.

The workflows preserve PR validation, independent tagged-commit validation, upload of the tested root script and a separate least-privilege draft-release job. The shared container workflow adds .NET 10, .NET 11 and combined builds on Ubuntu AMD64 and native ARM64 runners. It selects exact installed GA SDKs after Codebelt's patch-precision setup; no SDKs are installed at container execution time. Container validation uses the latest **published** engine, while the existing Windows jobs test the checkout's engine. This distinction also applies during tag validation before that tag's draft is published.

Workflows use `codebeltnet/git-checkout@v1` and `codebeltnet/install-dotnet@v3`. The Codebelt OCI publishing action requires product SemVer tags and does not implement these SDK-environment conventions, so Docker publication stays in the developer-controlled module. `actions/upload-artifact` has no suitable Codebelt equivalent and is pinned to the inspected v7 commit, following this task's explicit third-party SHA requirement. No Docker Hub credentials or publishing job are added to PR or release workflows. GitHub-hosted execution remains to be verified after an approved push.

Release v0.2.0 deliberately:

1. Review the feature branch, then obtain explicit approval to commit, push and open its PR. Merge only after separate approval and successful Windows and container CI validation.
2. On the approved release commit, rerun the relevant checks. With approval, create and push the annotated v0.2.0 tag; the existing workflow validates it and creates a draft with the tested standalone script attached.
3. Review the draft and asset. With approval, publish the GitHub release so the canonical latest-release asset selects the new engine.
4. From a clean, reviewed checkout, inspect `BuildAndPublish -WhatIf -PassThru`. Obtain Docker publication approval, log in to Docker Hub, and run the three explicit SDK builds above with separate metadata files. Each resolves the latest release once, tests its exact asset, and publishes only the three SDK tags for its environment. For multiple architectures within one publication, pass both platforms in the same invocation to reuse one resolved engine asset.
5. Inspect the resulting registry digests and attestations, rerun the public one-liners, and add the digest metadata to release notes. No image or release is published automatically by local validation.

Implementation references: [.NET file-based applications](https://learn.microsoft.com/en-us/dotnet/core/sdk/file-based-apps), [SDK stdin design and project precedence](https://github.com/dotnet/sdk/blob/main/documentation/general/dotnet-run-file.md), [xUnit MTP configuration](https://xunit.net/docs/getting-started/v3/microsoft-testing-platform), and [MTP exit codes](https://learn.microsoft.com/en-us/dotnet/core/testing/microsoft-testing-platform-exit-codes).
