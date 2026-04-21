import Foundation
import AppKit

@MainActor
final class FileSearchModule: SearchProviderModule {
    let moduleId = "file"
    private let folderModuleId = "folder"

    private let fileProvider: FileSearchProvider
    private let folderProvider: FileSearchProvider

    init() {
        self.fileProvider = FileSearchProvider(contentType: .excludeFolders)
        self.folderProvider = FileSearchProvider(contentType: .foldersOnly)
    }

    func register(router: SearchRouter, settings: AppSettings) {
        router.register(prefix: settings.fileSearchPrefix, id: moduleId, provider: fileProvider)
        router.register(prefix: settings.folderSearchPrefix, id: folderModuleId, provider: folderProvider)
    }

    func applySettings(_ settings: AppSettings, router: SearchRouter) {
        router.setEnabled(settings.fileSearchEnabled, forId: moduleId)
        router.setEnabled(settings.folderSearchEnabled, forId: folderModuleId)
        router.updatePrefix(settings.fileSearchPrefix, forId: moduleId)
        router.updatePrefix(settings.folderSearchPrefix, forId: folderModuleId)
    }
}
