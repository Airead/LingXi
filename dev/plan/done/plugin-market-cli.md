# Phase 7: Plugin Market CLI (Install / Uninstall / List)

## Design Overview

The plugin market CLI enables users to discover, install, uninstall, and update plugins from the official GitHub registry.

### Key Design Decisions

> **重要约定**：所有 LingXi 缓存路径禁止硬编码。后续所有缓存相关内容统一放在 `~/.cache/LingXi/` 目录下，通过共享配置或环境变量获取，确保一致性和可维护性。

1. **Remote Registry**: Official `registry.toml` is fetched from GitHub (`https://raw.githubusercontent.com/Airead/LingXi/main/plugins/registry.toml`)
2. **Local Cache**: Registry is cached at `~/.cache/LingXi/registry.toml` with a 24-hour TTL
3. **Plugin Installation**: Downloads `plugin.toml` + all files listed in its `files` array from the same base URL
4. **No ZIP Support**: Each file is downloaded individually from GitHub raw URLs
5. **Version Compatibility**: Installation rejected if `min_lingxi_version` > current app version
6. **Disabled by Default**: All plugins disabled via `disabled_plugins` config until explicitly enabled
7. **Manual Plugins**: User-copied plugins (without `install.toml`) load with `MANUALLY_PLACED` status
8. **Update Detection**: Compare registry version with `install.toml.installed_version`
9. **CLI First**: Configuration UI will be implemented in a separate phase

### Directory Structure

```
~/.cache/LingXi/
  registry.toml                # Cached official registry

~/.config/LingXi/
  plugins/
    io.github.airead.lingxi.emoji-search/
      plugin.toml              # Downloaded from registry source
      plugin.lua               # Downloaded from registry source
      install.toml             # Generated locally
      ...other files from files[]
```

### `registry.toml` Format

```toml
name = "LingXi Official"
url = "https://github.com/Airead/LingXi"

[[plugins]]
id = "io.github.airead.lingxi.emoji-search"
name = "Emoji Search"
version = "1.0.0"
description = "Search emojis by keyword"
author = "LingXi Team"
source = "https://raw.githubusercontent.com/Airead/LingXi/main/plugins/emoji-search/plugin.toml"
min_lingxi_version = "0.1.0"
```

### `plugin.toml` Extended Format (with `files` array)

```toml
[plugin]
id = "io.github.airead.lingxi.emoji-search"
name = "Emoji Search"
description = "Search emojis by keyword"
version = "1.0.0"
author = "LingXi Team"
url = "https://github.com/Airead/LingXi"
min_lingxi_version = "0.1.0"

files = [
    "plugin.lua",
    "emoji-data.json",
]

[search]
prefix = "emoji"

[permissions]
network = true
clipboard = false
shell = []
```

### `install.toml` Format

```toml
[install]
source_url = "https://raw.githubusercontent.com/Airead/LingXi/main/plugins/emoji-search/plugin.toml"
installed_version = "1.0.0"
installed_at = "2026-04-22T10:00:00Z"
pinned_ref = ""            # Reserved for future pin feature
```

### Plugin Status Enum

```swift
enum PluginStatus: String {
    case notInstalled = "not_installed"
    case installed = "installed"
    case updateAvailable = "update_available"
    case manuallyPlaced = "manually_placed"
    case disabled = "disabled"
}
```

---

## Phase 7.1: Registry Manager

### Work

1. **Registry Data Structures**
   - Create `LingXi/Plugin/PluginRegistry.swift`:
     - `PluginRegistryEntry`: name, url
     - `RegistryPlugin`: id, name, version, description, author, sourceURL, minLingXiVersion
   - `RegistryParser`: Uses existing `TOMLParser` to parse `registry.toml`

2. **Registry Manager**
   - Create `LingXi/Plugin/RegistryManager.swift`:
     - `fetchRegistry()` async: Download from `BUILTIN_REGISTRY_URL`
     - `cachedRegistry() throws -> [RegistryPlugin]`: Read from cache
     - `refreshRegistry()` async throws: Download + write to cache
     - Cache TTL: 24 hours (check modification date)
     - Fallback to cache if network fails

3. **Version Comparison Utility**
   - Create `LingXi/Plugin/Semver.swift`:
     - `Semver.compare(_:_:) -> ComparisonResult`
     - Support `major.minor.patch` format

### Verification

1. Create local `registry.toml` in a temp directory:
   ```toml
   name = "Test Registry"
   url = "https://github.com/test/test"

   [[plugins]]
   id = "test.plugin"
   name = "Test Plugin"
   version = "1.0.0"
   source = "https://example.com/test/plugin.toml"
   min_lingxi_version = "0.1.0"
   ```

2. **Manual Verification**:
   - `RegistryParser` correctly parses test registry
   - `Semver.compare("1.0.0", "1.0.1")` returns `.orderedAscending`
   - `RegistryManager` fetches from a test URL and caches to temp directory
   - Offline: `cachedRegistry()` returns cached data without network call
   - Check cache file exists at expected path after fetch

---

## Phase 7.2: Plugin Market Core

### Work

1. **Install Manifest Parser/Writer**
   - Create `LingXi/Plugin/InstallManifest.swift`:
     - `InstallInfo` struct: sourceURL, installedVersion, installedAt, pinnedRef
     - `read(from: URL) throws -> InstallInfo`
     - `write(_: InstallInfo, to: URL) throws`
     - Uses existing `TOMLParser` (or manual TOML serialization)

2. **Plugin Market Actor**
   - Create `LingXi/Plugin/PluginMarket.swift`:
     - `PluginMarket` actor
     - `install(id: String) async throws`: From registry
     - `install(url: URL) async throws`: From direct plugin.toml URL
     - `uninstall(id: String) async throws`: Delete plugin directory
     - `listInstalled() -> [InstalledPluginInfo]`: Scan plugins dir
     - `listAvailable() async throws -> [RegistryPlugin]`: From registry
     - `checkUpdates() -> [UpdateInfo]`: Compare versions
   - Download logic:
     1. Download `plugin.toml` from source URL
     2. Parse manifest, check `min_lingxi_version` compatibility
     3. Create `~/.config/LingXi/plugins/<id>/` directory
     4. Download all files listed in `files` array (from same base URL)
     5. Write `install.toml`
     6. Add to `disabled_plugins` config (disabled by default)

3. **Path Security**
   - Validate plugin ID: no path traversal characters (`..`, `/`, `\`)
   - Sanitize directory name from plugin ID (replace `/` with `-`)

### Verification

1. **Create test plugin files** in a temporary HTTP server (or use local file URLs):
   - `plugin.toml` with `files = ["plugin.lua"]`
   - `plugin.lua` with a simple `search()` function

2. **Manual Verification**:
   - `plugin:install <test-id>` downloads files to `plugins/<id>/`
   - Check `plugins/<id>/install.toml` exists with correct version
   - Check `disabled_plugins` config includes the new plugin ID
   - `plugin:uninstall <id>` deletes the directory
   - `plugin:install <url>` works with direct plugin.toml URL
   - Incompatible version (e.g., `min_lingxi_version = "99.0.0"`) shows error

---

## Phase 7.3: CLI Commands Integration

### Work

1. **Enhance PluginManager**
   - Add `uninstall(pluginId:)` method
   - Add `installedPlugins` property that reads from filesystem
   - Enhance `summary` to include version, status, source info

2. **Add CLI Commands to CommandModule**
   - `plugin:install <id>` — Install from registry
   - `plugin:install <url>` — Install from URL (args starts with `http`)
   - `plugin:uninstall <id>` — Uninstall plugin
   - `plugin:update <id>` — Update single plugin
   - `plugin:update` — Update all plugins with available updates
   - `plugin:enable <id>` — Enable plugin (remove from `disabled_plugins`)
   - `plugin:disable <id>` — Disable plugin (add to `disabled_plugins`)
   - Enhance `plugin:list` — Show version, status, source
   - `plugin:registry refresh` — Force refresh registry cache

3. **Disable Logic in PluginManager**
   - Read `disabled_plugins` from AppSettings
   - Skip loading plugins in `disabled_plugins` list
   - `plugin:enable/disable` modifies AppSettings + reloads

### Verification

1. **Manual Verification**:
   - Install a test plugin via `plugin:install`
   - `plugin:list` shows: `[prefix] name v1.0.0 (disabled)`
   - `plugin:enable <id>` → reload → plugin is active
   - `plugin:disable <id>` → reload → plugin is inactive but files remain
   - `plugin:uninstall <id>` → directory removed
   - `plugin:update` detects and installs new versions
   - `plugin:registry refresh` updates cache file modification time

---

## Phase 7.4: Manual Plugin Detection

### Work

1. **Detect Manually Placed Plugins**
   - In `PluginManager.loadAll()`, after scanning plugin directories:
     - If directory has `plugin.toml` but no `install.toml` → `MANUALLY_PLACED`
     - Still load the plugin (unlike disabled)
     - Log a warning: "Manually placed plugin detected: <id>"

2. **Show in CLI**
   - `plugin:list` shows `(manual)` for manually placed plugins
   - `plugin:uninstall` works on manual plugins too (just deletes directory)

### Verification

1. **Manual Verification**:
   - Create a plugin directory manually at `plugins/test.manual/`
   - Add `plugin.toml` and `plugin.lua` but no `install.toml`
   - Restart LingXi → `plugin:list` shows `(manual)` status
   - Plugin functions correctly
   - `plugin:uninstall test.manual` removes directory

---

## Phase 7.5: Update Detection

### Work

1. **Update Check Logic**
   - `PluginMarket.checkUpdates()`:
     - Scan all installed plugins (with `install.toml`)
     - For each, find matching entry in registry
     - Compare `registry.version` vs `install.toml.installed_version`
     - If registry > installed → `UPDATE_AVAILABLE`

2. **Update Flow**
   - `plugin:update <id>`:
     1. Check if update available
     2. Backup old plugin directory (e.g., `plugins/<id>.backup/`)
     3. Re-download all files
     4. On failure → restore backup
     5. Update `install.toml.installed_version`
     6. Reload plugins

3. **Auto-Check on Launch**
   - Optional: Check for updates in background on app launch
   - Log a warning if updates available (no UI yet since CLI phase)

### Verification

1. **Manual Verification**:
   - Install a plugin at version `1.0.0`
   - Manually edit cache `registry.toml` to show version `1.0.1`
   - `plugin:list` shows `(update available)`
   - `plugin:update <id>` downloads new version
   - Check `install.toml` version is now `1.0.1`
   - Plugin functions correctly after update

---

## Rollback Strategy

- Commit after each sub-phase
- On failure: revert to previous commit

## Notes

1. **Concurrency**: `PluginMarket` is an actor; download operations run off MainActor
2. **Test Isolation**: Tests use temp directories; never touch `~/.config/LingXi/`
3. **Logging**: Use `DebugLog.log()` for all operations
4. **Error Handling**: Network errors, parse errors, permission errors all surface to user via command output
5. **Security**: Validate plugin IDs, prevent directory traversal, verify downloaded content
