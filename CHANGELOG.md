# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.0]: https://github.com/codebeltnet/csrun/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/codebeltnet/csrun/releases/tag/v0.1.0
