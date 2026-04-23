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

## Reference

- Review [docs/ai-swift-macos-best-practices.md](docs/ai-swift-macos-best-practices.md) for AI-assisted Swift macOS development best practices including Swift 6.2 concurrency, SwiftUI architecture, and testing strategy.
