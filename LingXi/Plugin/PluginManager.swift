import Foundation

/// Metadata parsed from a Lua plugin's `plugin` global table.
struct PluginManifest: Sendable {
    let name: String
    let prefix: String
    let description: String
    let debounce: Int
    let timeout: Int
}

/// Discovers and loads Lua plugins from the plugins directory.
enum PluginManager {
    static let pluginsDirectory: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/LingXi/plugins", isDirectory: true)

    struct LoadedPlugin: Sendable {
        let manifest: PluginManifest
        let provider: LuaSearchProvider
    }

    /// Discover and load all plugins from the plugins directory.
    static func loadAll(from directory: URL = pluginsDirectory) -> [LoadedPlugin] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            DebugLog.log("[PluginManager] Plugins directory not found: \(directory.path)")
            return []
        }

        var plugins: [LoadedPlugin] = []
        for entry in entries {
            guard entry.hasDirectoryPath else { continue }

            let scriptPath = entry.appendingPathComponent("plugin.lua").path
            do {
                let plugin = try loadPlugin(scriptPath: scriptPath, pluginDir: entry)
                plugins.append(plugin)
                DebugLog.log("[PluginManager] Loaded plugin: \(plugin.manifest.name) (prefix: \"\(plugin.manifest.prefix)\")")
            } catch {
                DebugLog.log("[PluginManager] Failed to load \(entry.lastPathComponent): \(error)")
            }
        }

        return plugins
    }

    private static func loadPlugin(scriptPath: String, pluginDir: URL) throws -> LoadedPlugin {
        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)
        try state.doFile(scriptPath)

        let manifest = readManifest(from: state, dirName: pluginDir.lastPathComponent)

        let provider = LuaSearchProvider(
            name: manifest.name,
            pluginDir: pluginDir,
            state: state,
            debounce: manifest.debounce,
            timeout: manifest.timeout
        )

        return LoadedPlugin(manifest: manifest, provider: provider)
    }

    /// Read the `plugin` global table from a Lua state to extract manifest info.
    private static func readManifest(from state: LuaState, dirName: String) -> PluginManifest {
        state.getGlobal("plugin")
        defer { state.pop() }

        guard state.isTable(at: -1) else {
            return PluginManifest(
                name: dirName,
                prefix: dirName,
                description: "",
                debounce: 100,
                timeout: 5000
            )
        }

        let name = state.stringField("name", at: -1) ?? dirName
        let prefix = state.stringField("prefix", at: -1) ?? dirName
        let description = state.stringField("description", at: -1) ?? ""
        let debounce = state.numberField("debounce", at: -1).map { Int($0) } ?? 100
        let timeout = state.numberField("timeout", at: -1).map { Int($0) } ?? 5000

        return PluginManifest(
            name: name,
            prefix: prefix,
            description: description,
            debounce: debounce,
            timeout: timeout
        )
    }
}
