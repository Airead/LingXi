# LingXi

## Bundle ID

The app bundle identifier is `io.github.airead.lingxi.LingXi`. Use `io.github.airead.lingxi.*` as the prefix for DispatchQueue labels and other reverse-DNS identifiers.

## Concurrency

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all code runs on MainActor by default.
- Use `@concurrent` for async work that should run off the main actor (network, IO, heavy computation).
- Mark pure data functions as `nonisolated`.
- Prefer Swift actor over manual locking (NSLock, DispatchQueue) for thread-safe shared state.

## Testing

Run unit tests with parallel testing disabled and skip UI tests:

```bash
xcodebuild test -scheme LingXi -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LingXiTests
```

**Avoid running multiple `xcodebuild` processes concurrently** — they compete for DerivedData and CodeSign, causing hangs or build failures. Always wait for the previous build/test to finish before starting a new one.

**Never use real user data in tests.** Use isolated/mock resources instead of the real system state. For example, use a custom `NSPasteboard(name:)` instead of `.general`, use a temporary directory instead of `~/Desktop`, and use in-memory `UserDefaults` instead of `.standard`.

## Actor Pitfalls

- `deinit` is nonisolated. Accessing actor-isolated stored properties from `deinit` will deadlock. Use `nonisolated(unsafe)` for properties that must be read/cancelled in `deinit` (e.g. `DispatchSource`, `Task`).

## Logging

Use `DebugLog.log()` for all logging in the main app. Do not use `print()`, `NSLog()`, or `OSLog` directly.

## Cache Directory

All app caches are stored in `~/.cache/LingXi/`:

- `~/.cache/LingXi/registry.toml` — Plugin registry cache
- `~/.cache/LingXi/<plugin-id>/` — Per-plugin isolated cache directory

Use `RegistryManager.cacheDirectory` as the root for all cache operations.

## Release

Releases are fully automated by CI (`.github/workflows/release.yml`), triggered by pushing a `v*` tag to GitHub (`origin`). CI extracts the version from the tag, sets `MARKETING_VERSION`, builds, signs, packages a DMG, and creates the GitHub Release — no manual version bump is needed.

To release version `X.Y.Z`:

```bash
git push origin main       # make sure the release commits are on GitHub
git tag vX.Y.Z             # tag the release commit
git push origin vX.Y.Z     # triggers the Release workflow
```

Notes:

- Tags must be pushed to `origin` (GitHub); the `bwga` remote is a mirror and does not trigger CI.
- A tag containing `-` (e.g. `v0.1.0-beta.1`) is published as a prerelease.
- Local release builds (`make build-release` / `make build-dmg`) derive the version from the latest reachable git tag.

## Reference

- Review [docs/ai-swift-macos-best-practices.md](docs/ai-swift-macos-best-practices.md) for AI-assisted Swift macOS development best practices including Swift 6.2 concurrency, SwiftUI architecture, and testing strategy.
