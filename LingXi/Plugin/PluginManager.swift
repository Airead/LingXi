import Foundation

/// Metadata parsed from a Lua plugin's `plugin` global table.
struct PluginManifest: Sendable {
    let name: String
    let prefix: String
    let description: String
    let debounce: Int
    let timeout: Int
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
    private(set) var directory: URL
    private(set) var plugins: [LoadedPlugin] = []
    private(set) var failures: [(dirName: String, error: String)] = []

    init(router: SearchRouter, directory: URL = pluginsDirectory) {
        self.router = router
        self.directory = directory
    }

    /// Load all plugins and register them with the router.
    func loadAll() async {
        let dir = directory
        let results = await Task.detached { Self.scanDirectory(dir) }.value
        applyResults(results)
    }

    /// Reload all plugins: unregister old ones, re-scan, register new ones.
    func reload() async {
        for plugin in plugins {
            router.unregister(id: plugin.routerId)
        }
        plugins.removeAll()
        failures.removeAll()
        await loadAll()
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

    private func applyResults(_ results: [LoadResult]) {
        for result in results {
            switch result {
            case .loaded(let plugin):
                plugins.append(plugin)
                router.register(
                    prefix: plugin.manifest.prefix,
                    id: plugin.routerId,
                    provider: plugin.provider
                )
                DebugLog.log("[PluginManager] Loaded plugin: \(plugin.manifest.name) (prefix: \"\(plugin.manifest.prefix)\")")
            case .failed(let dirName, let error):
                failures.append((dirName: dirName, error: error))
                DebugLog.log("[PluginManager] Failed to load \(dirName): \(error)")
            }
        }
    }

    nonisolated private static func scanDirectory(_ directory: URL) -> [LoadResult] {
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
                let plugin = try loadPlugin(scriptPath: scriptPath, pluginDir: entry)
                results.append(.loaded(plugin))
            } catch {
                results.append(.failed(dirName: entry.lastPathComponent, error: "\(error)"))
            }
        }

        return results
    }

    nonisolated private static func loadPlugin(scriptPath: String, pluginDir: URL) throws -> LoadedPlugin {
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

    nonisolated private static func readManifest(from state: LuaState, dirName: String) -> PluginManifest {
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
