import AppKit

final class BookmarkSearchProvider: SearchProvider, @unchecked Sendable {
    private let store: BookmarkStore
    private var browserIconCache: [String: NSImage] = [:]
    private let iconCacheLock = NSLock()

    init(store: BookmarkStore = BookmarkStore()) {
        self.store = store
    }

    func search(query: String) async -> [SearchResult] {
        scoredResults(from: store.bookmarks, query: query, names: \.searchableFields) { bookmark, score in
            SearchResult(
                itemId: "bookmark:\(bookmark.url.absoluteString)",
                icon: browserIcon(for: bookmark.browserBundleId),
                name: bookmark.title,
                subtitle: bookmark.url.absoluteString,
                resultType: .bookmark,
                url: bookmark.url,
                score: score,
                modifierActions: [
                    .command: ModifierAction.copyURL,
                ],
                openWithBundleId: bookmark.browserBundleId
            )
        }
    }

    private func browserIcon(for bundleId: String) -> NSImage? {
        iconCacheLock.lock()
        let cached = browserIconCache[bundleId]
        iconCacheLock.unlock()
        if let cached { return cached }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 32, height: 32)

        iconCacheLock.lock()
        browserIconCache[bundleId] = icon
        iconCacheLock.unlock()

        return icon
    }
}
