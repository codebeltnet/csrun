# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-15

This minor release adds optional disposable Ubuntu container execution while preserving the standalone native PowerShell engine and manifest schema version 1.

### Added

- Added `csrun.Dockerfile` and a UTF-8 stdin adapter for console samples and genuine xUnit v3 tests, with non-root execution and read-only root filesystem support,
- Added a self-contained `BuildAndPublish` module with explicit single/combined SDK environments, existing SDK tag conventions, verified latest-release engine assets, image identity metadata, and Buildx SBOM/provenance publication options,
- Added Docker integration tests and Ubuntu AMD64/ARM64 CI validation alongside the existing native Windows tests, plus container usage, isolation, image caching and deliberate publication documentation.

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
