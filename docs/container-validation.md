# Container validation

The initial validation below predates the OCI delivery changes. Local validation on 2026-11-15 used PowerShell 7 on Windows, Docker Desktop 4.97.0 with Linux AMD64 containers, Docker Engine 29.9.2 and Buildx 0.38.1. That local session published no images. Subsequent native CI validation and v0.2.0 Docker Hub publication are recorded separately below. The native executor is unchanged from the released source.

## Engine and base identities

The canonical latest-release asset resolved to `v0.1.0` during these operations. GitHub's asset digest and the bundled file both matched SHA-256 `6609acb7ac9df5cbbbf70d58b3dbc40f2d242e34831f89c7b42d7069015db802`. Each build records this engine version/checksum in image labels. Future builds resolve the latest release again; there is no version-specific engine URL in the build tooling.

| Environment | Exact installed SDKs | NETCore and ASP.NET Core runtimes | Official Ubuntu base index digest |
| --- | --- | --- | --- |
| `10` | `10.0.404` | `10.0.15` | Noble: `sha256:fe0fd4e93bd2fbb47c883b7a6369e5c8d3db8bf01cdc5981f6ee35fbdf3ff4fb` |
| `11` | `11.0.100` | `11.0.0` | Resolute: `sha256:65f3c7c6a25a239ab3e6719f2896147e7b68242ff2d8818dd70498bde6ef8bea` |
| `10-11` | `10.0.404`, `11.0.100` | `10.0.15`, `11.0.0` | Same Resolute base as `11` |

Inventories are checked against Microsoft's exact per-channel SDK release metadata, including both runtime families. The combined environment contains both SDKs, not just extra runtimes, and executes manifests for both `net10.0` and `net11.0`.

## Image sizes

Docker's local image inspection reports these uncompressed logical sizes for `linux/amd64`; these are not compressed registry transfer sizes or incremental disk usage with shared layers:

| Environment | Bytes | MiB |
| --- | ---: | ---: |
| `10` | 1,315,204,771 | 1,254.3 |
| `11` | 1,268,622,586 | 1,209.9 |
| `10-11` | 2,169,181,898 | 2,068.7 |

The combined image adds about 859 MiB over the .NET 11 image to retain the .NET 10 SDK, targeting packs and shared runtimes. The .NET 11 single image is smaller than the .NET 10 image despite its newer SDK; the official Ubuntu image contents differ. Single-SDK images provide the smaller environment for one TFM. No persistent NuGet cache or debugger tooling is added.

## Checks

- Native Windows: 91 full regression/integration checks passed on SDK 11.0.100; 15 compatibility checks passed on SDK 10.0.115. `csrun.ps1` has no repository diff.
- Publishing contract: 9 checks passed, covering dry-run/PassThru tags, prerelease normalization, collisions, invalid inputs, custom options, unsupported metadata channels, exact historical SDK lookup and Docker error propagation without Docker or network access.
- Final AMD64 container suites passed: 21 checks for .NET 10, 21 for .NET 11 and 22 for the combined image (64 total). They cover exact SDK/runtime inventories, baked asset identity, stdin console samples and genuine xUnit v3 discovery, Codebelt console/test packages and visible MTP output, compilation and assertion failures, empty discovery, UTF-8/large manifests, validation failures, missing TFMs, the engine's LTS default, ASP.NET framework references, non-root/no-host-mount defaults, disposable storage, and hardened read-only execution with executable tmpfs and resource limits.
- All PowerShell files parsed successfully, all three workflow files passed actionlint, and `git diff --check` passed. Both `-WhatIf -PassThru` planning and actual `-BuildOnly -PassThru` operations were exercised.
- A real Git-tagged MinVer package build produces `1.2.3` with Git and falls back to `0.0.0-alpha.0` when Git is unavailable. This is why the official SDK image's Git installation is retained.
- Network-disabled JSON validation exercises the bundled engine without a startup download. Normal compilation and tests keep network enabled for release metadata and NuGet. Caching the release index alone did not make a console restore offline-capable; offline builds are not promised.

Both exact console and xUnit stdin one-liners were executed from Windows PowerShell against the locally built `codebeltnet/csrun:10` image and returned `0`, with `42` and one passing test respectively. Further exit-code checks include console exit `23`, compilation exit `1`, MTP failed assertion exit `2` and no-test exit `8`.

## OCI delivery verification

The refreshed build path exports BuildKit OCI content once with SBOM and maximum provenance, converts that content for native testing, and compares raw Docker-exported config bytes with the original OCI config. This matters on Docker Desktop's containerd image store: its image ID can be a manifest digest rather than a config digest. A changed serialization is not treated as changed filesystem/config content.

- The unchanged standalone engine again passed all 106 Windows checks: 91 with SDK 11.0.100 and 15 with SDK 10.0.115.
- Eleven publishing-module contracts pass, including fork registry/context plans and rejection of a foreign Docker CPU before downloads.
- Twenty offline artifact/lifecycle tests pass. They cover exact platform inventory, config/source/SDK/engine identity, missing or unrelated SBOM/provenance, provenance build arguments, corrupt archives/blobs, preservation of manifests during assembly, split/recovery byte identity, draft/stale releases, fork source identities, and rejection of Docker `latest` before any upload.
- The generic Codebelt `oci-artifact-verify@v1` verifier accepted an assembled two-platform contract fixture. This validates the archive contract, not ARM64 execution.
- Real AMD64 OCI exports include nonempty SPDX SBOMs and SLSA provenance bound to their platform manifests and source/engine/SDK build inputs. An unnamed BuildKit export initially emitted empty attestation subjects; the verifier rejected it. Naming the export fixed the subjects.
- All three refreshed OCI exports passed native AMD64 execution and exact exported-config verification: 22 checks for .NET 10, 22 for .NET 11, and 23 for the combined image (67 total). The combined image compiles and executes console and xUnit samples on both TFMs.

Refreshed export measurements are below. Docker reports local image storage differently after Docker-format import; these values are not directly comparable with the initial build's logical size measurements. OCI archive bytes include compressed layers, manifests and attestations, and are a better guide to artifact transfer/storage. Neither measure promises incremental disk usage with shared layers.

| Environment | Docker-reported local image bytes | OCI archive bytes |
| --- | ---: | ---: |
| `10` | 1,978,122,006 | 390,060,032 |
| `11` | 1,427,258,798 | 360,735,744 |
| `10-11` | 2,734,862,369 | 608,526,336 |

The earlier local candidate verification used checked-out bytes, annotated `v0.2.0`; that evidence alone did not establish publication. Its script checksum was `6609acb7ac9df5cbbbf70d58b3dbc40f2d242e34831f89c7b42d7069015db802`.

## Subsequent v0.2.0 CI and publication evidence

The [v0.2.0 release run](https://github.com/codebeltnet/csrun/actions/runs/43772479751) subsequently passed all six native container jobs: SDK variants `10`, `11`, and `10-11` on AMD64 (`ubuntu-26.04`) and ARM64 (`ubuntu-26.04-arm`), plus both Windows engine jobs and release artifact preparation. This establishes native ARM64 execution beyond the earlier local fixtures. The [v0.2.0 GitHub Release](https://github.com/codebeltnet/csrun/releases/tag/v0.2.0) was published on 2026-11-15.

The successful [Docker Hub deployment run](https://github.com/codebeltnet/csrun/actions/runs/43777998665) on 2026-11-16 validated the saved release artifacts for all three SDK variants and promoted them without rebuilding, including registry content inspection. These are subsequent CI/publication results, not claims about the earlier local session or validation of v0.2.1.

## v0.2.1 workload integrity policy

The maintainer confirmed that both documented console and xUnit commands returned `0` with the expected output but also emitted `An issue was encountered verifying workloads. For more information, run "dotnet workload update".` Setting `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=true` eliminated that warning; `DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=true` was tested and did not solve it.

The Dockerfile now sets only `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=true` in its existing container environment declarations. According to [Microsoft](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-environment-variables#dotnet_skip_workload_integrity_check), this skips the first-run check that workloads from previous SDK feature bands remain accessible to the current SDK. Disposable console/test execution therefore omits that particular check; consumers relying on optional workloads must account for the limitation and can restore the default with `-e DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=false`. Native execution is unchanged. No stderr filtering or changes to NuGet verification, compiler diagnostics, SDK vulnerability checking, SDK selection, inventories, or OCI identity/SBOM/provenance validation are introduced. Those controls do not replace the skipped check.

The extended container suite checks the declared default and its value inside a running console manifest, an explicit `false` override in the entry point's process before SDK execution, successful console and genuine xUnit v3 execution without the warning in combined stdout/stderr, compilation and assertion diagnostics with their nonzero exit codes, identical SDK/runtime inventories with the check enabled and skipped, and hardened read-only execution. The override test does not require the restored SDK integrity check to succeed.

### Local patch verification (2026-11-16)

Both README manifests were reproduced against the existing local `codebeltnet/csrun:10` image labelled `v0.2.0`: console output `42`, one discovered/passing xUnit test, exit `0` for each, and the workload warning in both combined output captures. This independently confirms the maintainer's reproduction.

Candidate images were built from the worktree with `BuildAndPublish -BuildOnly`, the unchanged local engine labelled `v0.2.1`, and exact SDK inputs `10.0.404` and `11.0.100`. These are local test artifacts, not published v0.2.1 release artifacts. Docker Desktop's native AMD64 daemon was used; this does not establish execution on the requested GitHub-hosted Ubuntu runners.

| SDK variant | Native local AMD64 container checks | OCI SBOM/provenance and loaded-config verification |
| --- | --- | --- |
| `10` | 23 passed, 0 failed | Passed |
| `11` | 23 passed, 0 failed | Passed |
| `10-11` | 24 passed, 0 failed | Passed |

All 70 container checks passed. For every installed channel, console output `42` and one discovered/passing xUnit test retained exit `0` without the workload warning in combined stdout/stderr. Compilation errors retained exit `1` and compiler diagnostics; failed assertions retained exit `2` and assertion diagnostics; no-test execution retained exit `8`. Inventory comparisons, the explicit environment override, and hardened read-only console/test execution passed in every variant. Each exported OCI archive passed the existing identity, SPDX SBOM, SLSA provenance, and byte-equivalent loaded-config verification.

- Standalone Windows engine: 91 checks passed with SDK `11.0.100`; 15 compatibility checks passed with SDK `10.0.115`.
- Independent publishing module: 12 contract checks passed; OCI artifact/lifecycle suite: 27 tests passed.
- PowerShell parsing and `git diff --check` passed. `csrun.ps1` retains SHA-256 `6609acb7ac9df5cbbbf70d58b3dbc40f2d242e34831f89c7b42d7069015db802`; manifest schema version 1, entry point, publishing module, OCI tooling, and workflows are unchanged.

Native ARM64 is unavailable in the configured local Docker contexts. The unchanged CI matrix still requires SDK variants `10`, `11`, and `10-11` on both `ubuntu-26.04` (AMD64) and `ubuntu-26.04-arm` (ARM64). That v0.2.1 hosted matrix was not run: the patch remains local, with no push, release creation, or image publication authorized. Historical v0.2.0 CI results above do not substitute for this validation.

## Limits and release work

- The earlier local ARM64 `exec format error` was a host execution limitation, not a confirmed image defect. No privileged emulation was installed. Subsequent v0.2.0 CI established native ARM64 execution; v0.2.1 still requires its own native matrix on `ubuntu-26.04` and `ubuntu-26.04-arm` before release completion.
- No Docker Hub credentials or publication are used for this patch's local validation. The successful v0.2.0 deployment is historical evidence; v0.2.1 publication and registry inspection require separate authorization. BuildKit predicate validation does not introduce a separate signing authority.
- Release preparation packages the candidate engine and native-tested platform content into durable, checksummed draft GitHub Release assets. After publication, CD resolves the canonical latest script once, requires its release identity and exact checksum to match, and promotes existing content. Deployment recovery never rebuilds or substitutes missing artifacts.
- Preserve required branch checks and the `Production` approval controls. Only its publishing step receives Docker Hub credentials. See the README for the independent manual builder, native remote contexts, release asset storage and controlled recovery procedures.

## Release-versioned alias validation (0.2.2 worktree, 2026-11-16)

The additive publishing contract was validated locally without building or publishing images. The standalone `csrun.ps1` remains unchanged with SHA-256 `6609acb7ac9df5cbbbf70d58b3dbc40f2d242e34831f89c7b42d7069015db802`; manifest schema version 1 and container execution are unchanged.

- PowerShell publishing contracts: **14 passed**, covering the exact single/combined SDK matrices, unchanged convenience aliases, appended release identities, prerelease normalization, collisions, invalid/missing identities, the Docker tag-length limit, offline dry runs, custom registries/native contexts/builders, and verified fork-owned engine acquisition with explicit version mismatch and checksum rejection.
- Python OCI/release contracts: **39 passed**, including real offline PowerShell planner integration, both tag families in saved release metadata, exact index identity for all six aliases in each SDK environment, preserved child manifests/SBOM/provenance, absent/matching/conflicting registry tags, fail-closed registry errors, immediate conflict rechecks, partial-publication retries, stale-release rejection, and all-variant preflight before any writes. Registry operations use isolated mocks; they are not evidence of real registry publication.
- Matching versioned digests skip upload and still undergo registry content verification. Conflicting versioned destinations fail before convenience writes; versioned aliases are rechecked immediately before attempted publication. A simulated interruption preserves completed versioned aliases and recovery publishes the remaining names against the original index.
- Historical convenience-only metadata remains recoverable without inventing release-versioned aliases. This migration path preserves saved tag lists and refuses stale releases under the existing latest-release policy.
- The release/container workflow files remain unchanged: six native jobs still run SDK variants `10`, `11`, and `10-11` on `ubuntu-26.04` and `ubuntu-26.04-arm`. Deployment still requires `Production` approval and promotes saved verified OCI artifacts. Its publishing orchestration now restores all variants, preflights every versioned destination, publishes/verifies versioned names across all variants, and only then moves convenience names. Any failure stops promotion; retry uses the original artifacts.

No native AMD64/ARM64 builds, GitHub-hosted jobs, Docker Hub writes, release publication or historical backfills were performed for this change. The tests establish the publishing contract with fixtures; the retained native CI matrix and real registry checks must still run before a release is considered validated in production.

Client-side checks cannot close the registry check/write race against concurrent or external writers. Configure selective registry-enforced immutability for release-versioned tags when available, retain movable convenience aliases, and restrict registry writers. The tooling does not change repository settings. Consumers requiring immutable selection should pin the published index digest.

Read-only GitHub release inspection found OCI parts and release records for all three variants in both `v0.2.0` and `v0.2.1`. These historical records predate release-versioned aliases. A safe backfill may be possible from the original saved artifacts after revalidating their checksums, native records, release identity, attestations and destination conflicts; the large OCI parts were not downloaded/revalidated here. No backfill is approved or performed, and no historical release notes or image identities were modified.

### PR #7 regression follow-up

The first PR run failed all six container jobs in the publishing-contract step: calling the PowerShell test file from a parent script hid its `Assert-Throws` helper from the module session. The earlier direct `pwsh -File` invocation did not expose that scope boundary. Passing the assertion scriptblock explicitly fixes the existing test without changing the CI invocation or runner matrix. The CI-style `pwsh -Command '& ./tests/BuildAndPublish.Tests.ps1'` now passes all **14 checks** on Windows and in a local native Linux AMD64 container, using the already installed `codebeltnet/csrun:10` image with networking disabled and a read-only source mount.

The Python suite now passes **41 tests**, including a parent-script invocation regression and captured Skopeo error diagnostics for both registry preflight and post-push inspection. Unexpected captured errors retain stderr in their exception text, return code and subprocess error type; expected missing-manifest responses remain handled as absent tags. This validates the fixes locally; the hosted native matrix has not been rerun for this follow-up, and no registry writes were performed.
