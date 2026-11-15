# csrun

Run a complete C# console example or genuine xUnit v3 tests with one standalone PowerShell script. No clone, project creation, IDE, or global installation is required for readers.

Requires PowerShell 7 and an installed .NET 10+ SDK with support for file-based applications and the requested target framework/runtime. The samples and integration suite use .NET SDK **11.0.100**, targeting **net11.0**. The runner never installs SDKs or retargets source. NuGet access is required for packages not already cached.

## Copy & Run

The release URL below is the intended deployment target. It becomes usable after the maintainer publishes the first release in `gimlichael/csrun`; no release is published by this change. The local Git remote currently points to `codebeltnet/csrun`, so the maintainer must choose the intended hosting repository and adjust the URL if necessary.

```powershell
& ([scriptblock]::Create((irm 'https://github.com/gimlichael/csrun/releases/latest/download/csrun.ps1'))) -ManifestJson '{"schemaVersion":1,"mode":"console","framework":"net11.0","source":"System.Console.WriteLine(\"Hello from Codebelt!\");"}'
```

For longer source, use an inline JSON here-string in the same invocation:

```powershell
& ([scriptblock]::Create((irm 'https://github.com/gimlichael/csrun/releases/latest/download/csrun.ps1'))) -ManifestJson @'
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

## Local use

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

Direct options default to `console`, `net11.0`, and no packages. Source defaults to `Get-Clipboard -Raw` when available; an empty/unavailable clipboard produces an error. `-Source`, `-File`, and `-Clipboard` are mutually exclusive. `-ManifestJson` excludes all direct configuration and input options. Both paths use the same validation and execution implementation. Invoke from PowerShell when passing package arrays; native `pwsh -File` does not bind comma-separated strings as arrays.

## Manifest version 1

| Field | Contract |
| --- | --- |
| `schemaVersion` | Required integer `1`. |
| `mode` | Required `console` or `test`, case-insensitive. |
| `framework` | Required .NET 10+ TFM such as `net11.0` or `net11.0-windows`; earlier targets and RIDs such as `win-x64` are invalid. Platform availability is checked by the SDK. |
| `source` | Required nonempty string containing a complete program or test source. Multiline text, quotes, Unicode, and line endings are preserved. |
| `dependsOn` | Optional array of `PackageId@ExactVersion` pins, including prereleases. Identical duplicates collapse; conflicting versions, ranges, wildcards, and unversioned packages fail. Use three or four numeric version components. |
| `sdk` | Optional `Microsoft.NET.Sdk` (default) or `Microsoft.NET.Sdk.Web`. Never inferred. |
| `frameworkReferences` | Optional array of framework reference names. Test projects emit explicit, XML-escaped references. For console applications, only `Microsoft.AspNetCore.App` with explicitly selected `Microsoft.NET.Sdk.Web` is supported, through the SDK's implicit reference. Other console references fail with a diagnostic. |

Unknown fields are rejected to expose misspellings. No package discovery, source wrapping, method mode, or source rewriting occurs. Ordinary transitive NuGet dependencies still resolve normally. Source-only methods without a runnable entry point produce the actual compiler error.

Console mode prepends SDK, target framework, and pinned package directives to the source stream and invokes `dotnet run -`. If a current-directory project exists, SDK 11 would select it first; csrun instead uses an isolated temporary `.cs` file and `dotnet run --file` to force file-based execution while retaining the program's working directory. It creates no console project. The SDK manages its own normal build cache. Approximate NuGet matches and downgrades are errors, preventing an unavailable pin from silently becoming another version.

Existing source directives must be in the leading preamble (blank lines, leading comments, and C# preprocessor directives such as `#nullable` are permitted). Only matching SDK, target framework, and manifest package directives are supported. Matching directives remain in the original source and are not emitted again. Multiple occurrences of the same source setting fail explicitly because the SDK rejects duplicate directives. Conflicts and other preamble directives also fail explicitly. Build customization outside this contract belongs in a future schema, not arbitrary MSBuild directives.

Test mode writes the original source to a minimal executable project in a unique temporary directory and runs `dotnet run --project ... -- --show-live-output on --progress off --no-banner`. It uses **xunit.v3@4.0.3** by default, with `UseMicrosoftTestingPlatformRunner=true`. Explicit stable xunit.v3 **4.0 patch versions >= 4.0.3** are accepted as the supported MTP v2 compatibility band; other engine variants and incompatible versions are rejected. User packages are added as exact NuGet references. The project is removed in `finally` after successful runs, compilation/restore errors, or failed tests. Forced process termination cannot guarantee cleanup.

The Codebelt example discovers one passing test and displays `started`, `2`, and `finished` through live `ITestOutputHelper` output. Its `HasTestOutput` assertion only checks that an output helper exists; the integration suite separately verifies the three visible lines. Facts, theories, async tests, constructor injection, fixture disposal, and skipped tests run through the actual xUnit engine. Failed assertions return MTP exit **2**; an empty assembly returns **8**. csrun preserves child stdout/stderr and exit status; validation and prerequisite failures return **1**. `$LASTEXITCODE` is available after local invocation; `pwsh -File ./csrun.ps1 ...` propagates it to the shell. A remote scriptblock's `exit` can end the calling PowerShell command/session; use a separate `pwsh` process if session isolation is needed.

Pinned package/TFM execution is distinct from downloading the latest script release. Complete reproduction also depends on the installed SDK/runtime, NuGet configuration and transitive dependencies, platform, and any external services used by the program. Test projects live outside the caller's directory and do not depend on its `dotnet test` runner selection; the selected `dotnet` SDK still respects applicable `global.json` selection. There is no implicit runtime roll-forward or SDK installation.

## Validation and releases

Run the dependency-free regression and integration suite:

```powershell
pwsh -NoProfile -File ./tests/csrun.Tests.ps1
```

Tests invoke the actual standalone script in child processes, including local scriptblock invocation of the release asset. Fixtures preserve the supplied full DateSpan and Codebelt xUnit examples. DateSpan with Cuemon.Kernel 11.0.0 prints `0 years`, `9 months`, **`40 weeks`**, `273 days`, `6552 hours`, `393,120 minutes`, and `23,587,200 seconds`. Windows is the locally validated platform; paths and process invocation are portable, but Linux/macOS are not yet locally verified.

The workflows follow the [claude-autoupdate release pattern](https://github.com/gimlichael/claude-autoupdate/tree/main/.github/workflows): PR validation; independent validation of a tagged commit; upload of the tested root script; a separate least-privilege job creating a **draft** release from that artifact. Actions are pinned to commit SHAs. No additional repository secrets are needed. GitHub-hosted workflow execution must be verified after an approved push.

To make the initial release, after reviewing and approving this local change:

1. Commit the feature branch and approve pushing/opening a PR. Merge the reviewed change into `main` after PR validation passes.
2. On the approved release commit, run the tests above, then create an annotated tag: `git tag -a v0.1.0 -m "csrun v0.1.0"`.
3. With approval, push that specific tag: `git push origin v0.1.0`. The tag workflow reruns tests and creates a draft with only `csrun.ps1` attached.
4. Review the draft and download the asset for inspection. With maintainer approval, publish the draft. The latest-release URL then resolves in the repository where the release was published. A version-specific URL (`releases/download/v0.1.0/csrun.ps1`) pins script delivery too.

Implementation references: [.NET file-based applications](https://learn.microsoft.com/en-us/dotnet/core/sdk/file-based-apps), [SDK stdin design and project precedence](https://github.com/dotnet/sdk/blob/main/documentation/general/dotnet-run-file.md), [xUnit MTP configuration](https://xunit.net/docs/getting-started/v3/microsoft-testing-platform), and [MTP exit codes](https://learn.microsoft.com/en-us/dotnet/core/testing/microsoft-testing-platform-exit-codes).
