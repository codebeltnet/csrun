# Container validation

Local validation on 2026-11-15 uses Windows PowerShell 7, Docker Desktop 4.97.0 with Linux AMD64 containers, Docker Engine 29.9.2 and Buildx 0.38.1. No images were published. The native executor is unchanged from the released source.

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

## Limits and release work

- ARM64 local execution is unavailable: the official ARM64 base image fails with `exec format error`, including a direct `uname` invocation. No privileged emulator installation was attempted. The workflow configures native Ubuntu ARM64 runners, but their execution is unverified until an approved push. Multi-architecture support is not yet established.
- PR/tag workflows, registry publication, generated SBOM/provenance attestations and final registry digests have not been exercised remotely. No Docker Hub credentials were used. Buildx publication explicitly requests SBOM/provenance and writes digest metadata; validate those outputs during the approved publication operation.
- The v0.2.0 changelog entry is a draft until the approved release is published. Publish the reviewed GitHub release before rebuilding images if they should contain its new engine; pre-publication container CI intentionally uses the current latest published asset.
- See the README for the exact test commands, hardened one-liner, module options and release sequence. Preserve `artifacts/*.json` from approved builds and attach published registry digests to release notes.
