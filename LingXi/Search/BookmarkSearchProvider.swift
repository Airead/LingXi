import AppKit

actor BookmarkSearchProvider: SearchProvider {
    private let store: BookmarkStore
    private let iconCache = AppIconCache()

    init(store: BookmarkStore = BookmarkStore()) {
        self.store = store
    }

    func search(query: String) async -> [SearchResult] {
        let bookmarks = await store.bookmarks
        return scoredItems(from: bookmarks, query: query, names: { $0.searchableFields }).map { bookmark, score in
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
        iconCache.icon(for: bundleId)
    }
}
