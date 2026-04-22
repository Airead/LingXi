import Foundation

/// An entry in the official plugin registry.
nonisolated struct RegistryPlugin: Sendable, Equatable {
    let id: String
    let name: String
    let version: String
    let description: String
    let author: String
    let sourceURL: URL
    let minLingXiVersion: String
}

/// The root registry document.
nonisolated struct PluginRegistry: Sendable {
    let name: String
    let url: String
    let plugins: [RegistryPlugin]
}

/// Parses `registry.toml` into structured data.
nonisolated enum RegistryParser {
    enum Error: Swift.Error, Equatable {
        case missingField(String)
        case invalidURL(String)
    }

    static func parse(_ text: String) throws -> PluginRegistry {
        let doc = try TOMLParser.parse(text)

        guard let name = doc.string("", "name"), !name.isEmpty else {
            throw Error.missingField("name")
        }
        let url = doc.string("", "url") ?? ""

        var plugins: [RegistryPlugin] = []
        if let pluginTables = doc.tableArray("plugins") {
            for table in pluginTables {
                guard let id = table["id"]?.stringValue, !id.isEmpty else {
                    throw Error.missingField("plugins.id")
                }
                guard let pluginName = table["name"]?.stringValue, !pluginName.isEmpty else {
                    throw Error.missingField("plugins.name")
                }
                guard let source = table["source"]?.stringValue,
                      let sourceURL = URL(string: source) else {
                    throw Error.invalidURL(table["source"]?.stringValue ?? "")
                }

                plugins.append(RegistryPlugin(
                    id: id,
                    name: pluginName,
                    version: table["version"]?.stringValue ?? "",
                    description: table["description"]?.stringValue ?? "",
                    author: table["author"]?.stringValue ?? "",
                    sourceURL: sourceURL,
                    minLingXiVersion: table["min_lingxi_version"]?.stringValue ?? ""
                ))
            }
        }

        return PluginRegistry(name: name, url: url, plugins: plugins)
    }
}
