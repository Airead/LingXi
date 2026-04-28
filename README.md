# LingXi

A modular macOS search launcher with Lua plugin support.

## Requirements

- macOS 14+
- Xcode 15+

## Build

```bash
make build           # Debug build
make build-release   # Release build
make install         # Install to /Applications
```

## Test

```bash
make test
```

## Plugins

Built-in providers: applications, files, bookmarks, system settings, clipboard, snippets, commands. Third-party plugins live under `plugins/` and are written in Lua.

See [docs/architecture.md](docs/architecture.md) for the architecture overview.
