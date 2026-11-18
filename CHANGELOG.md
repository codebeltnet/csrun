# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.2] - 2026-11-18

This patch release extends Docker publishing with release-versioned SDK aliases alongside the existing movable convenience tags. The standalone native PowerShell engine (`csrun.ps1`), manifest schema version 1 and container execution contract remain unchanged.

### Added

- Added a `-vMAJOR.MINOR.PATCH` alias for every existing SDK environment tag, derived from the verified engine release or explicit validated local-engine version, with separate convenience/versioned `-PassThru` metadata and unresolved offline planning placeholders,
- Added release-versioned destination preflight, matching-digest retries, explicit conflict rejection and exact OCI index digest verification to the shared manual/CI publisher; deployment preflights every SDK variant and verifies all versioned aliases before moving convenience aliases, preserving native checks, attestations, saved release artifacts and stale-release protection without additional builds,
- Added regression coverage and documentation for both tag families, fork publishing and manual recovery, compatibility/version axes, registry concurrency and selective immutability, digest pinning and security-update expectations; historical convenience-only recovery retains its saved aliases without synthesizing historical versioned tags.

## [0.2.1] - 2026-11-16

This patch release cleans disposable container output by skipping a specific .NET SDK first-run workload integrity check, with the verification trade-off and opt-in restoration documented. The standalone native PowerShell engine (`csrun.ps1`) and manifest schema version 1 remain unchanged.

### Changed

- Changed the container-runtime default to `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=true`, skipping the check that workloads from previous SDK feature bands remain accessible to the current SDK to avoid the warning during successful console and xUnit execution; consumers requiring this verification can restore the SDK default with `-e DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=false`,
- Documented the optional-workload limitation and unchanged SDK selection, diagnostics, NuGet behavior, exit codes, image identity, pinned SDK inputs, native architecture tests, and OCI SBOM/provenance controls, which do not replace the skipped check,
- Extended container regression coverage for warning-free console and genuine xUnit v3 execution, environment overrides, unchanged inventories, real failure diagnostics, and hardened read-only execution, and distinguished earlier local validation from subsequent v0.2.0 native CI and Docker Hub publication evidence,
- Clarified the README title and introduction as C# Example & Test Runner (`csrun`), and reworded the container usage introduction to refer to the published Docker images.

## [0.2.0] - 2026-11-15

This minor release adds optional disposable Ubuntu container execution and SDK environment publishing, while the standalone native PowerShell engine (`csrun.ps1`) and manifest schema version 1 remain unchanged.

### Added

- Added `csrun.Dockerfile` and a UTF-8 stdin entry point, so a manifest piped to `docker run --rm -i` runs the bundled engine inside a Linux container with the selected .NET SDKs preinstalled, for console samples and xUnit v3 tests,
- Added the `BuildAndPublish` module, which resolves exact .NET SDK versions to environment tags, builds the container image, writes an OCI archive with image identity metadata, and publishes only when explicitly requested,
- Added Docker integration tests in `tests/container.Tests.ps1` that cover SDK inventories, stdin execution, exit codes, and hardened read-only execution, plus Ubuntu AMD64 and ARM64 container validation in CI,
- Added README and `docs/container-validation.md` documentation for container usage, isolation limits, and SDK environment publishing.

### Changed

- Changed the release workflow to attach the tested OCI image archives and a `csrun.ps1.sha256` checksum to the draft GitHub release,
- Changed the pull request workflow to add a required quality gate that fails unless the Windows and container jobs succeed, and to pin Windows jobs to `windows-2025`.

## [0.1.0] - 2026-11-15

This is the first release that introduces csrun as a standalone PowerShell script for running complete C# console programs and xUnit v3 tests from a manifest, a source file, or inline source, with framework defaults resolved from Microsoft's official .NET release index.

### Added

- Added `csrun.ps1`, a standalone PowerShell 7 script that runs a complete C# console program or xUnit v3 test from a schemaVersion 1 JSON manifest, a source file, or inline source,
- Added `console` and `test` modes, where `test` runs xUnit v3 tests on the Microsoft Testing Platform and preserves the test process exit status,
- Added `dependsOn` support for exact `PackageId@ExactVersion` NuGet pins, including prerelease versions,
- Added the optional `sdk` and `frameworkReferences` manifest fields, where console mode accepts `Microsoft.AspNetCore.App` only with `Microsoft.NET.Sdk.Web`,
- Added a default target framework of the highest supported GA LTS channel, with explicit .NET 10 or later targets validated against Microsoft's release index cached for up to 12 hours,
- Added a scriptblock invocation path that leaves the calling PowerShell session alive and sets `$LASTEXITCODE`,
- Added sample manifests for console, date span, xUnit output, and LTS default usage,
- Added a regression and integration test suite in `tests/csrun.Tests.ps1` with its fixtures,
- Added pull request and tag release workflows that run the test suite on Windows with the .NET 11 SDK and a .NET 10 compatibility job, then create a draft GitHub release with the tested `csrun.ps1` attached,
- Added the MIT license.

[0.2.2]: https://github.com/codebeltnet/csrun/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/codebeltnet/csrun/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/codebeltnet/csrun/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/codebeltnet/csrun/releases/tag/v0.1.0
