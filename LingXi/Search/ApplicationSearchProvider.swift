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

    /// User-facing apps from CoreServices that don't appear in standard search paths.
    static nonisolated let defaultCoreServicesApps = [
        "/System/Library/CoreServices/Finder.app",
        "/System/Library/CoreServices/Siri.app",
        "/System/Library/CoreServices/Applications/About This Mac.app",
        "/System/Library/CoreServices/Applications/Archive Utility.app",
        "/System/Library/CoreServices/Applications/Directory Utility.app",
        "/System/Library/CoreServices/Applications/Keychain Access.app",
        "/System/Library/CoreServices/Applications/Ticket Viewer.app",
    ]

    private nonisolated static let modifierActions = ModifierAction.defaultFileActions

    private nonisolated static let runningBoost: Double = 10
    private nonisolated static let runningCacheTTL: TimeInterval = 20

    private let apps: [AppEntry]
    private let iconCache = AppIconCache()
    private var cachedRunningIds: Set<String> = []
    private var lastRunningFetch: Date = .distantPast

    init(
        searchPaths: [String] = ApplicationSearchProvider.defaultSearchPaths,
        coreServicesApps: [String] = ApplicationSearchProvider.defaultCoreServicesApps
    ) {
        let fileManager = FileManager.default

        var entries: [AppEntry] = []
        var seen = Set<String>()

        func addApp(_ url: URL) {
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard !seen.contains(resolvedPath) else { return }
            seen.insert(resolvedPath)

            let bundle = Bundle(url: url)
            let name = Self.appName(from: bundle, url: url)
            let bundleIdentifier = bundle?.bundleIdentifier ?? ""
            entries.append(AppEntry(name: name, bundleIdentifier: bundleIdentifier, url: url))
        }

        for path in searchPaths {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: nil
            ) else { continue }

            for url in contents where url.pathExtension == "app" && !url.lastPathComponent.hasPrefix(".") {
                addApp(url)
            }
        }

        for path in coreServicesApps where fileManager.fileExists(atPath: path) {
            addApp(URL(fileURLWithPath: path))
        }

        self.apps = entries
        Task { await self.preloadIcons() }
    }

    func search(query: String) async -> [SearchResult] {
        let scored = scoredItems(from: apps, query: query, names: \.searchableNames)

        let runningBundleIds = fetchRunningAppBundleIds()

        return scored.map { app, score in
            let icon = iconCache.icon(forFile: app.url.path)
            let itemId = app.bundleIdentifier.isEmpty ? app.url.path : app.bundleIdentifier
            let isRunning = !app.bundleIdentifier.isEmpty && runningBundleIds.contains(app.bundleIdentifier)
            let boostedScore = isRunning ? score + Self.runningBoost : score
            let subtitle = isRunning ? "Running — \(app.url.path)" : app.url.path
            return SearchResult(
                itemId: itemId, icon: icon, name: app.name, subtitle: subtitle,
                resultType: .application, url: app.url, score: boostedScore,
                modifierActions: Self.modifierActions
            )
        }
    }

    private func fetchRunningAppBundleIds() -> Set<String> {
        let now = Date()
        if now.timeIntervalSince(lastRunningFetch) < Self.runningCacheTTL {
            return cachedRunningIds
        }
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        cachedRunningIds = ids
        lastRunningFetch = now
        return ids
    }

    private func preloadIcons() async {
        await iconCache.preload(paths: apps.map { $0.url.path })
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
