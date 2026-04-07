import Foundation

/// Event names dispatched to Lua plugins. Each corresponds to a global Lua function.
nonisolated enum PluginEvent: String {
    case clipboardChange = "on_clipboard_change"
    case searchActivate = "on_search_activate"
}

/// A command declared by a Lua plugin in `plugin.commands`.
struct PluginCommand: Sendable {
    let name: String
    let title: String
    let subtitle: String
    let actionFunctionName: String
}

/// Metadata parsed from a Lua plugin's `plugin` global table.
struct PluginManifest: Sendable {
    let name: String
    let prefix: String
    let description: String
    let debounce: Int
    let timeout: Int
    let commands: [PluginCommand]
}

/// A successfully loaded plugin.
struct LoadedPlugin: Sendable {
    let manifest: PluginManifest
    let provider: LuaSearchProvider
    var routerId: String { "\(LuaSearchProvider.idPrefix)\(manifest.name)" }
}

/// Discovers and loads Lua plugins from the plugins directory.
@MainActor
final class PluginManager {
    private enum LoadResult: Sendable {
        case loaded(LoadedPlugin)
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
    /// Command names registered by plugins (for cleanup on reload).
    private var registeredCommandNames: Set<String> = []

    init(router: SearchRouter, directory: URL = pluginsDirectory) {
        self.router = router
        self.directory = directory
    }

    /// Load all plugins and register them with the router.
    func loadAll() async {
        let dir = directory
        let results = await Task.detached { await Self.scanDirectory(dir) }.value
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
        await loadAll()
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
        if plugins.isEmpty && failures.isEmpty {
            lines.append("No plugins found in \(directory.path)")
        }
        for p in plugins {
            lines.append("[\(p.manifest.prefix)] \(p.manifest.name) — \(p.manifest.description)")
        }
        for f in failures {
            lines.append("[error] \(f.dirName) — \(f.error)")
        }
        return lines.joined(separator: "\n")
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

    nonisolated private static func scanDirectory(_ directory: URL) async -> [LoadResult] {
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
        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)
        LuaAPI.registerAll(state: state)
        try state.doFile(scriptPath)

        let manifest = readManifest(from: state, dirName: pluginDir.lastPathComponent)

        let provider = await LuaSearchProvider(
            name: manifest.name,
            pluginDir: pluginDir,
            state: state,
            debounce: manifest.debounce,
            timeout: manifest.timeout
        )

        return LoadedPlugin(manifest: manifest, provider: provider)
    }

    nonisolated private static func readManifest(from state: LuaState, dirName: String) -> PluginManifest {
        state.getGlobal("plugin")
        defer { state.pop() }

        guard state.isTable(at: -1) else {
            return PluginManifest(
                name: dirName,
                prefix: dirName,
                description: "",
                debounce: 100,
                timeout: 5000,
                commands: []
            )
        }

        let name = state.stringField("name", at: -1) ?? dirName
        let prefix = state.stringField("prefix", at: -1) ?? dirName
        let description = state.stringField("description", at: -1) ?? ""
        let debounce = state.numberField("debounce", at: -1).map { Int($0) } ?? 100
        let timeout = state.numberField("timeout", at: -1).map { Int($0) } ?? 5000
        let commands = readCommands(from: state, pluginTableIndex: -1)

        return PluginManifest(
            name: name,
            prefix: prefix,
            description: description,
            debounce: debounce,
            timeout: timeout,
            commands: commands
        )
    }

    nonisolated private static func readCommands(from state: LuaState, pluginTableIndex: Int32) -> [PluginCommand] {
        state.getField("commands", at: pluginTableIndex)
        defer { state.pop() }

        guard state.isTable(at: -1) else { return [] }

        var commands: [PluginCommand] = []
        state.iterateArray(at: -1) {
            guard state.isTable(at: -1) else { return }
            let name = state.stringField("name", at: -1) ?? ""
            let title = state.stringField("title", at: -1) ?? ""
            let action = state.stringField("action", at: -1) ?? ""
            guard !name.isEmpty, !title.isEmpty, !action.isEmpty else { return }
            let subtitle = state.stringField("subtitle", at: -1) ?? ""
            commands.append(PluginCommand(
                name: name,
                title: title,
                subtitle: subtitle,
                actionFunctionName: action
            ))
        }
        return commands
    }
}
