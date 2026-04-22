import Foundation

/// Represents the contents of `install.toml` for an installed plugin.
nonisolated struct InstallInfo: Sendable, Equatable {
    let sourceURL: URL
    let installedVersion: String
    let installedAt: Date
    let pinnedRef: String
}

/// Reads and writes `install.toml` files.
nonisolated enum InstallManifest {
    enum Error: Swift.Error {
        case invalidFormat(String)
    }

    static func read(from url: URL) throws -> InstallInfo {
        let text = try String(contentsOf: url, encoding: .utf8)
        let doc = try TOMLParser.parse(text)

        guard let source = doc.string("install", "source_url"),
              let sourceURL = URL(string: source) else {
            throw Error.invalidFormat("Missing or invalid source_url")
        }
        guard let version = doc.string("install", "installed_version") else {
            throw Error.invalidFormat("Missing installed_version")
        }

        let installedAt: Date
        if let dateStr = doc.string("install", "installed_at") {
            let formatter = ISO8601DateFormatter()
            installedAt = formatter.date(from: dateStr) ?? Date()
        } else {
            installedAt = Date()
        }

        let pinnedRef = doc.string("install", "pinned_ref") ?? ""

        return InstallInfo(
            sourceURL: sourceURL,
            installedVersion: version,
            installedAt: installedAt,
            pinnedRef: pinnedRef
        )
    }

    static func write(_ info: InstallInfo, to url: URL) throws {
        let formatter = ISO8601DateFormatter()
        let dateStr = formatter.string(from: info.installedAt)

        let text = """
        [install]
        source_url = "\(info.sourceURL.absoluteString)"
        installed_version = "\(info.installedVersion)"
        installed_at = "\(dateStr)"
        pinned_ref = "\(info.pinnedRef)"
        """

        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
