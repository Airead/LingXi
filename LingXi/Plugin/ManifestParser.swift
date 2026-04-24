import Foundation

/// Parses plugin manifests from TOML files.
nonisolated enum ManifestParser {

    /// Read `plugin.toml` from the plugin directory.
    /// Throws if the file does not exist or is invalid.
    static func parseTOMLManifest(from pluginDir: URL) throws -> PluginManifest {
        let tomlPath = pluginDir.appendingPathComponent("plugin.toml")
        guard FileManager.default.fileExists(atPath: tomlPath.path) else {
            throw TOMLParser.Error.syntaxError(line: 0, message: "plugin.toml not found in \(pluginDir.lastPathComponent)")
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
        let minLingXiVersion = doc.string("plugin", "min_lingxi_version")
            ?? doc.string("plugin", "minLingXiVersion")
            ?? ""
        let files = doc.stringArray("plugin", "files") ?? []

        // Search config
        let searchPrefix = doc.string("search", "prefix")
        let searchDebounce = doc.int("search", "debounce")
        let searchTimeout = doc.int("search", "timeout")
        let searchUsageBoost = doc.bool("search", "usage_boost")
        let prefix = searchPrefix ?? id
        let debounce = searchDebounce ?? 100
        let timeout = searchTimeout ?? 5000
        let usageBoost = searchUsageBoost ?? true

        // Permissions
        let network = doc.bool("permissions", "network") ?? false
        let clipboard = doc.bool("permissions", "clipboard") ?? false
        let filesystem = doc.stringArray("permissions", "filesystem") ?? []
        let shell = doc.stringArray("permissions", "shell") ?? []
        let notify = doc.bool("permissions", "notify") ?? false
        let store = doc.bool("permissions", "store") ?? false
        let webview = doc.bool("permissions", "webview") ?? false
        let cache = doc.bool("permissions", "cache") ?? false
        let permissions = PermissionConfig(
            network: network,
            clipboard: clipboard,
            filesystem: filesystem,
            shell: shell,
            notify: notify,
            store: store,
            webview: webview,
            cache: cache
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
            usageBoost: usageBoost,
            permissions: permissions,
            commands: commands,
            files: files
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
}
