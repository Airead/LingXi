import Foundation
import AppKit

@MainActor
final class BookmarkModule: SearchProviderModule {
    let moduleId = "bookmark"

    private let provider: BookmarkSearchProvider

    init(store: BookmarkStore = BookmarkStore()) {
        self.provider = BookmarkSearchProvider(store: store)
    }

    func register(router: SearchRouter, settings: AppSettings) {
        router.register(prefix: settings.bookmarkSearchPrefix, id: moduleId, provider: provider)
    }

    func applySettings(_ settings: AppSettings, router: SearchRouter) {
        router.setEnabled(settings.bookmarkSearchEnabled, forId: moduleId)
        router.updatePrefix(settings.bookmarkSearchPrefix, forId: moduleId)
    }
}
