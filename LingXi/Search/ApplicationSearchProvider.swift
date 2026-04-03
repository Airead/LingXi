import AppKit

final class ApplicationSearchProvider: SearchProvider {
    private struct AppEntry {
        let name: String
        let url: URL
    }

    static let defaultSearchPaths = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    private let apps: [AppEntry]
    private var iconCache: [URL: NSImage] = [:]
    private let iconCacheLock = NSLock()

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

                let name = Self.appName(for: url)
                entries.append(AppEntry(name: name, url: url))
            }
        }

        self.apps = entries
        preloadIcons()
    }

    func search(query: String) async -> [SearchResult] {
        scoredResults(from: apps, query: query, name: \.name) { app, score in
            let icon = iconForApp(at: app.url)
            return SearchResult(icon: icon, name: app.name, subtitle: app.url.path,
                                resultType: .application, url: app.url, score: score)
        }
    }

    private func iconForApp(at url: URL) -> NSImage {
        iconCacheLock.lock()
        let cached = iconCache[url]
        iconCacheLock.unlock()
        if let cached { return cached }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func preloadIcons() {
        let urls = apps.map(\.url)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for url in urls {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                self?.iconCacheLock.lock()
                self?.iconCache[url] = icon
                self?.iconCacheLock.unlock()
            }
        }
    }

    private static func appName(for url: URL) -> String {
        if let bundle = Bundle(url: url) {
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
