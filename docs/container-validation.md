# Container validation

The initial validation below predates the OCI delivery changes. Local validation on 2026-11-15 uses Windows PowerShell 7, Docker Desktop 4.97.0 with Linux AMD64 containers, Docker Engine 29.9.2 and Buildx 0.38.1. No images were published. The native executor is unchanged from the released source.

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

Candidate verification uses checked-out bytes, annotated `v0.2.0`; this is not evidence that a v0.2.0 GitHub Release has been published. Their script checksum remains `6609acb7ac9df5cbbbf70d58b3dbc40f2d242e34831f89c7b42d7069015db802`.

## Limits and release work

- The earlier local ARM64 `exec format error` is a host execution limitation, not a confirmed image defect. No privileged emulation was installed. Real ARM64 execution is required on `ubuntu-26.04-arm`; AMD64 uses `ubuntu-26.04`. Neither GitHub-hosted runner has been exercised in this session, and native ARM64 support is not established by local exports or fixture tests.
- No Docker Hub credentials were used and no registry publication or registry attestation preservation has been verified. BuildKit predicate validation does not introduce a separate signing authority. Authorized CI execution and a real push plus immutable registry inspection remain required before release completion.
- Release preparation packages the candidate engine and native-tested platform content into durable, checksummed draft GitHub Release assets. After publication, CD resolves the canonical latest script once, requires its release identity and exact checksum to match, and promotes existing content. Deployment recovery never rebuilds or substitutes missing artifacts.
- Configure required branch checks and reviewers for the `Production` environment before enabling publication. Only its publishing step receives Docker Hub credentials. See the README for the independent manual builder, native remote contexts, release asset storage and controlled recovery procedures.
