import Foundation

/// Event names dispatched to Lua plugins.
nonisolated enum PluginEvent: String {
    case clipboardChange = "clipboard_change"
    case searchActivate = "search_activate"
    case searchDeactivate = "search_deactivate"
    case appLaunch = "app_launch"
    case screenshotCaptured = "screenshot_captured"
    case pluginReload = "plugin_reload"
}

/// A successfully loaded plugin.
struct LoadedPlugin: Sendable {
    let manifest: PluginManifest
    let provider: LuaSearchProvider
    var routerId: String { "\(LuaSearchProvider.idPrefix)\(manifest.name)" }
}

/// Discovers and loads Lua plugins from the plugins directory.
@MainActor
final class PluginManager: PluginService {
    enum LoadResult: Sendable {
        case loaded(LoadedPlugin)
        case skipped(dirName: String, reason: String)
        case failed(dirName: String, error: String)
    }

    nonisolated static let pluginsDirectory: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/LingXi/plugins", isDirectory: true)

    private let router: SearchRouter
    private var commandProvider: CommandSearchProvider?
    private(set) var directory: URL
    private(set) var plugins: [LoadedPlugin] = []
    private(set) var failures: [(dirName: String, error: String)] = []
    private(set) var skipped: [(dirName: String, reason: String)] = []
    private var registeredCommandNames: Set<String> = []
    private let settings: AppSettings

    init(router: SearchRouter, directory: URL = pluginsDirectory, settings: AppSettings? = nil) {
        self.router = router
        self.directory = directory
        self.settings = settings ?? AppSettings.shared
    }

    /// Load all plugins and register them with the router.
    func loadAll() async {
        let dir = directory
        let disabled = Set(settings.disabledPlugins)
        let results = await Task.detached { await Self.scanDirectory(dir, disabled: disabled) }.value
        await applyResults(results)
    }

    /// Set the command provider so plugins can register custom commands.
    func setCommandProvider(_ provider: CommandSearchProvider) {
        self.commandProvider = provider
    }

    /// Reload all plugins: unregister old ones, re-scan, register new ones.
    func reload() async {
        for plugin in plugins {
            router.unregister(id: plugin.routerId)
        }
        await unregisterPluginCommands()
        plugins.removeAll()
        failures.removeAll()
        skipped.removeAll()
        await loadAll()
        await dispatchEvent(name: PluginEvent.pluginReload.rawValue, data: [:])
    }

    /// Dispatch an event to all loaded plugins concurrently.
    func dispatchEvent(name: String, data: [String: String]) async {
        await withTaskGroup(of: Void.self) { group in
            for plugin in plugins {
                group.addTask { await plugin.provider.dispatchEvent(name: name, data: data) }
            }
        }
    }

    /// Summary of loaded and failed plugins for display.
    var summary: String {
        var lines: [String] = []
        if plugins.isEmpty && failures.isEmpty && skipped.isEmpty {
            lines.append("No plugins found in \(directory.path)")
        }
        for p in plugins {
            let version = p.manifest.version.isEmpty ? "" : " v\(p.manifest.version)"
            lines.append("[\(p.manifest.prefix)] \(p.manifest.name)\(version) — \(p.manifest.description)")
        }
        for s in skipped {
            lines.append("[skipped] \(s.dirName) — \(s.reason)")
        }
        for f in failures {
            lines.append("[error] \(f.dirName) — \(f.error)")
        }
        return lines.joined(separator: "\n")
    }

    /// List all installed plugins on disk (including disabled and manual).
    func installedPlugins() -> [InstalledPluginInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let disabled = Set(settings.disabledPlugins)
        var results: [InstalledPluginInfo] = []
        for entry in entries where entry.hasDirectoryPath {
            guard let manifest = try? ManifestParser.parseTOMLManifest(from: entry) else { continue }
            let installTomlURL = entry.appendingPathComponent("install.toml")
            let installInfo = try? InstallManifest.read(from: installTomlURL)

            let status: PluginStatus
            if disabled.contains(manifest.id) {
                status = .disabled
            } else if installInfo == nil {
                status = .manuallyPlaced
            } else {
                status = .installed
            }

            results.append(InstalledPluginInfo(
                id: manifest.id,
                manifest: manifest,
                installInfo: installInfo,
                status: status
            ))
        }
        return results.sorted { $0.manifest.id < $1.manifest.id }
    }

    /// Uninstall a plugin by ID.
    func uninstall(pluginId: String) throws {
        guard isValidPluginID(pluginId) else {
            throw PluginMarketError.invalidPluginID(pluginId)
        }
        let pluginDir = directory.appendingPathComponent(sanitizeDirectoryName(pluginId))
        let fm = FileManager.default
        guard fm.fileExists(atPath: pluginDir.path) else {
            throw PluginMarketError.notInstalled(pluginId)
        }
        try fm.removeItem(at: pluginDir)
        DebugLog.log("[PluginManager] Uninstalled plugin: \(pluginId)")
    }

    // MARK: - Private

    private func applyResults(_ results: [LoadResult]) async {
        for result in results {
            switch result {
            case .loaded(let plugin):
                plugins.append(plugin)
                router.register(
                    prefix: plugin.manifest.prefix,
                    id: plugin.routerId,
                    provider: plugin.provider
                )
                await registerPluginCommands(for: plugin)
                DebugLog.log("[PluginManager] Loaded plugin: \(plugin.manifest.name) (prefix: \"\(plugin.manifest.prefix)\")")
            case .skipped(let dirName, let reason):
                skipped.append((dirName: dirName, reason: reason))
                DebugLog.log("[PluginManager] Skipped \(dirName): \(reason)")
            case .failed(let dirName, let error):
                failures.append((dirName: dirName, error: error))
                DebugLog.log("[PluginManager] Failed to load \(dirName): \(error)")
            }
        }
    }

    private func registerPluginCommands(for plugin: LoadedPlugin) async {
        guard let commandProvider else { return }
        let provider = plugin.provider
        for cmd in plugin.manifest.commands {
            if registeredCommandNames.contains(cmd.name) {
                DebugLog.log("[PluginManager] Command '\(cmd.name)' already registered, skipping duplicate from plugin '\(plugin.manifest.name)'")
                continue
            }
            let functionName = cmd.actionFunctionName
            let entry = CommandEntry(
                name: cmd.name,
                title: cmd.title,
                subtitle: cmd.subtitle,
                action: { args in
                    await provider.executeFunction(name: functionName, args: args)
                }
            )
            do {
                try await commandProvider.register(entry)
                registeredCommandNames.insert(cmd.name)
            } catch {
                DebugLog.log("[PluginManager] Failed to register command '\(cmd.name)': \(error)")
            }
        }
    }

    private func unregisterPluginCommands() async {
        guard let commandProvider else { return }
        for name in registeredCommandNames {
            await commandProvider.unregister(name)
        }
        registeredCommandNames.removeAll()
    }

    nonisolated private static func scanDirectory(_ directory: URL, disabled: Set<String>) async -> [LoadResult] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            DebugLog.log("[PluginManager] Plugins directory not found: \(directory.path)")
            return []
        }

        var results: [LoadResult] = []
        for entry in entries {
            guard entry.hasDirectoryPath else { continue }

            // Parse manifest to get ID and check disabled
            let manifest: PluginManifest
            do {
                manifest = try ManifestParser.parseTOMLManifest(from: entry)
            } catch {
                results.append(.failed(dirName: entry.lastPathComponent, error: "\(error)"))
                continue
            }

            // Skip disabled plugins
            if disabled.contains(manifest.id) {
                results.append(.skipped(dirName: entry.lastPathComponent, reason: "disabled"))
                continue
            }

            let scriptPath = entry.appendingPathComponent("plugin.lua").path
            do {
                let plugin = try await loadPlugin(scriptPath: scriptPath, pluginDir: entry)
                results.append(.loaded(plugin))
            } catch {
                results.append(.failed(dirName: entry.lastPathComponent, error: "\(error)"))
            }
        }

        return results
    }

    nonisolated private static func loadPlugin(scriptPath: String, pluginDir: URL) async throws -> LoadedPlugin {
        let manifest = try ManifestParser.parseTOMLManifest(from: pluginDir)

        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)

        LuaAPI.registerAll(state: state, permissions: manifest.permissions, pluginId: manifest.id)

        try state.doFile(scriptPath)

        let provider = await LuaSearchProvider(
            name: manifest.name,
            pluginDir: pluginDir,
            state: state,
            debounce: manifest.debounce,
            timeout: manifest.timeout
        )

        return LoadedPlugin(manifest: manifest, provider: provider)
    }
}
