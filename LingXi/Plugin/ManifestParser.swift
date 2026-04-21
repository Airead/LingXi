import Foundation

/// Parses plugin manifests from TOML files or Lua global tables.
nonisolated enum ManifestParser {

    /// Attempt to read `plugin.toml` from the plugin directory.
    /// Returns `nil` if the file does not exist.
    static func parseTOMLManifest(from pluginDir: URL) throws -> PluginManifest? {
        let tomlPath = pluginDir.appendingPathComponent("plugin.toml")
        guard FileManager.default.fileExists(atPath: tomlPath.path) else {
            return nil
        }
        let text = try String(contentsOf: tomlPath, encoding: .utf8)
        return try parseTOML(text)
    }

    /// Parse a TOML string into a `PluginManifest`.
    static func parseTOML(_ text: String) throws -> PluginManifest {
        let doc = try TOMLParser.parse(text)

        // Required fields under [plugin]
        guard let id = doc.string("plugin", "id"), !id.isEmpty else {
            throw TOMLParser.Error.syntaxError(line: 0, message: "Missing required field: plugin.id")
        }
        guard let name = doc.string("plugin", "name"), !name.isEmpty else {
            throw TOMLParser.Error.syntaxError(line: 0, message: "Missing required field: plugin.name")
        }
        let version = doc.string("plugin", "version") ?? ""
        let author = doc.string("plugin", "author") ?? ""
        let description = doc.string("plugin", "description") ?? ""
        let minLingXiVersion = doc.string("plugin", "minLingXiVersion") ?? ""

        // Search config
        let searchPrefix = doc.string("search", "prefix")
        let searchDebounce = doc.int("search", "debounce")
        let searchTimeout = doc.int("search", "timeout")
        let prefix = searchPrefix ?? id
        let debounce = searchDebounce ?? 100
        let timeout = searchTimeout ?? 5000

        // Permissions
        let network = doc.bool("permissions", "network") ?? false
        let clipboard = doc.bool("permissions", "clipboard") ?? false
        let filesystem = doc.stringArray("permissions", "filesystem") ?? []
        let shell = doc.stringArray("permissions", "shell") ?? []
        let notify = doc.bool("permissions", "notify") ?? false
        let permissions = PermissionConfig(
            network: network,
            clipboard: clipboard,
            filesystem: filesystem,
            shell: shell,
            notify: notify
        )

        // Commands
        let commands = parseCommands(from: doc)

        return PluginManifest(
            id: id,
            name: name,
            prefix: prefix,
            version: version,
            author: author,
            description: description,
            minLingXiVersion: minLingXiVersion,
            debounce: debounce,
            timeout: timeout,
            permissions: permissions,
            commands: commands
        )
    }

    /// Parse manifest from Lua global `plugin` table (backward compatibility).
    static func parseLuaManifest(from state: LuaState, dirName: String) -> PluginManifest {
        state.getGlobal("plugin")
        defer { state.pop() }

        guard state.isTable(at: -1) else {
            return PluginManifest(
                name: dirName,
                prefix: dirName,
                permissions: .backwardCompatible
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
            permissions: .backwardCompatible,
            commands: commands
        )
    }

    // MARK: - Private

    private static func parseCommands(from doc: TOMLParser.Document) -> [PluginCommand] {
        guard let tables = doc.tableArray("commands") else { return [] }

        var commands: [PluginCommand] = []
        for table in tables {
            guard let name = table["name"]?.stringValue, !name.isEmpty,
                  let title = table["title"]?.stringValue, !title.isEmpty,
                  let action = table["action"]?.stringValue, !action.isEmpty else {
                continue
            }
            let subtitle = table["subtitle"]?.stringValue ?? ""
            commands.append(PluginCommand(
                name: name,
                title: title,
                subtitle: subtitle,
                actionFunctionName: action
            ))
        }
        return commands
    }

    private static func readCommands(from state: LuaState, pluginTableIndex: Int32) -> [PluginCommand] {
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
