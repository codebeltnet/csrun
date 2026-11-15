# Repository instructions

## Engineering

- Prioritize correctness, inspect existing code before editing, and preserve compatible working behavior.
- Prefer the smallest safe, reversible change. Match existing naming, structure, and test conventions.
- State material assumptions and a short plan before nontrivial changes. Ask when missing information affects correctness or design.
- Validate changes with the relevant executable tests and report any validation limits honestly.
- Do not push, create a PR, or publish a release without explicit approval.

## .NET support policy

- Use only .NET 10 and later SDKs, runtimes, and application/test target frameworks. Do not introduce .NET 8, .NET 9, or older execution targets.
- Allowed release channels are supported LTS and STS releases, plus preview and go-live releases on .NET 10 or later. Exclude end-of-life channels.
- Verify support status and version choices against Microsoft's authoritative [release index](https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json), following its per-channel metadata when needed. Do not infer support status from the major version alone.
- Keep selected SDKs and direct NuGet dependencies pinned. Do not silently upgrade packages, retarget examples, or install SDKs at runner execution time.
- A dependency's compatible `lib/net8.0` asset can run on .NET 10+. Its asset TFM alone does not mean the .NET 8 runtime is used or that the package is unsupported. Assess package maintenance, advisories, and compatibility separately.
