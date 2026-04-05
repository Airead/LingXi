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

## Reference

- Review [docs/ai-swift-macos-best-practices.md](docs/ai-swift-macos-best-practices.md) for AI-assisted Swift macOS development best practices including Swift 6.2 concurrency, SwiftUI architecture, and testing strategy.
