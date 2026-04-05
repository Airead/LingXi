import AppKit

actor ApplicationSearchProvider: SearchProvider {
    private struct AppEntry {
        let name: String
        let bundleIdentifier: String
        let url: URL

        var searchableNames: [String] {
            var names = [name, url.deletingPathExtension().lastPathComponent]
            if !bundleIdentifier.isEmpty { names.append(bundleIdentifier) }
            return names
        }
    }

    static nonisolated let defaultSearchPaths = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    private nonisolated static let modifierActions = ModifierAction.defaultFileActions

    private let apps: [AppEntry]
    private var iconCache: [URL: NSImage] = [:]

    init(searchPaths: [String] = ApplicationSearchProvider.defaultSearchPaths) {
        let fileManager = FileManager.default

        var entries: [AppEntry] = []
        var seen = Set<String>()

        for path in searchPaths {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: nil
            ) else { continue }

            for url in contents where url.pathExtension == "app" && !url.lastPathComponent.hasPrefix(".") {
                let resolvedPath = url.resolvingSymlinksInPath().path
                guard !seen.contains(resolvedPath) else { continue }
                seen.insert(resolvedPath)

                let bundle = Bundle(url: url)
                let name = Self.appName(from: bundle, url: url)
                let bundleIdentifier = bundle?.bundleIdentifier ?? ""
                entries.append(AppEntry(name: name, bundleIdentifier: bundleIdentifier, url: url))
            }
        }

        self.apps = entries
        Task { await self.preloadIcons() }
    }

    func search(query: String) async -> [SearchResult] {
        scoredItems(from: apps, query: query, names: \.searchableNames).map { app, score in
            let icon = iconForApp(at: app.url)
            let itemId = app.bundleIdentifier.isEmpty ? app.url.path : app.bundleIdentifier
            return SearchResult(
                itemId: itemId, icon: icon, name: app.name, subtitle: app.url.path,
                resultType: .application, url: app.url, score: score,
                modifierActions: Self.modifierActions
            )
        }
    }

    private func iconForApp(at url: URL) -> NSImage {
        if let cached = iconCache[url] {
            return cached
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func preloadIcons() async {
        let urls = apps.map(\.url)
        let loaded = await Task.detached {
            urls.map { ($0, NSWorkspace.shared.icon(forFile: $0.path)) }
        }.value
        for (url, icon) in loaded {
            iconCache[url] = icon
        }
    }

    private static func appName(from bundle: Bundle?, url: URL) -> String {
        if let bundle {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !displayName.isEmpty {
                return displayName
            }
            if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !bundleName.isEmpty {
                return bundleName
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
