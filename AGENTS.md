# Repository instructions

## Engineering

- Prioritize correctness, inspect existing code before editing, and preserve compatible working behavior.
- Prefer the smallest safe, reversible change. Match existing naming, structure, and test conventions.
- State material assumptions and a short plan before nontrivial changes. Ask when missing information affects correctness or design.
- Validate changes with the relevant executable tests and report any validation limits honestly.
- Do not push, create a PR, or publish a release without explicit approval.

## GitHub Actions policy

- Prefer Codebelt actions and reusable workflows whenever they support the required behavior.
- Reference actions and reusable workflows with floating version tags, not commit SHAs.
- Use external actions only where the Codebelt ecosystem has no suitable equivalent.

- Use fixed `ubuntu-26.04` (AMD64) and `ubuntu-26.04-arm` (ARM64) runners for every Linux job. Never use `ubuntu-latest` or older Ubuntu runner labels. Keep Windows validation on `windows-2025`; runner upgrades require review.

## .NET support policy

- Use only .NET 10 and later SDKs, runtimes, and application/test target frameworks. Do not introduce .NET 8, .NET 9, or older execution targets.
- Allowed release channels are supported LTS and STS releases, plus preview and go-live releases on .NET 10 or later. Exclude end-of-life channels.
- Verify support status and version choices against Microsoft's authoritative [release index](https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json), following its per-channel metadata when needed. Do not infer support status from the major version alone.
- CI uses `codebeltnet/install-dotnet@v3` with patch precision to follow the current supported GA SDKs. Test runs select and verify an exact installed SDK for their required channel. Keep direct NuGet dependencies pinned. Do not silently upgrade packages, retarget examples, or install SDKs at runner execution time.
- An omitted framework selects the highest supported GA LTS channel; explicit frameworks are validated against the release index and never silently substituted. The latest preview or go-live channel is allowed only when explicitly requested.
