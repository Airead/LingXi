import Foundation

/// A command declared by a plugin manifest.
nonisolated struct PluginCommand: Sendable, Equatable {
    let name: String
    let title: String
    let subtitle: String
    let actionFunctionName: String
}

/// Plugin permission configuration.
nonisolated struct PermissionConfig: Sendable, Equatable {
    let network: Bool
    let clipboard: Bool
    let filesystem: [String]
    let shell: [String]
    let notify: Bool
    let store: Bool

    /// Restrictive default for plugins.
    nonisolated static let `default` = PermissionConfig(
        network: false,
        clipboard: false,
        filesystem: [],
        shell: [],
        notify: false,
        store: false
    )
}

/// Search configuration from manifest.
nonisolated struct SearchConfig: Sendable, Equatable {
    let prefix: String?
    let debounce: Int?
    let timeout: Int?
}

/// Metadata parsed from a plugin manifest (TOML or Lua global table).
nonisolated struct PluginManifest: Sendable, Equatable {
    let id: String
    let name: String
    let version: String
    let author: String
    let description: String
    let minLingXiVersion: String
    let prefix: String
    let debounce: Int
    let timeout: Int
    let permissions: PermissionConfig
    let commands: [PluginCommand]
    let files: [String]

    /// Create manifest with defaults for backward-compatible Lua-only plugins.
    init(
        id: String = "",
        name: String,
        prefix: String,
        version: String = "",
        author: String = "",
        description: String = "",
        minLingXiVersion: String = "",
        debounce: Int = 100,
        timeout: Int = 5000,
        permissions: PermissionConfig = .default,
        commands: [PluginCommand] = [],
        files: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.minLingXiVersion = minLingXiVersion
        self.prefix = prefix
        self.debounce = debounce
        self.timeout = timeout
        self.permissions = permissions
        self.commands = commands
        self.files = files
    }
}
