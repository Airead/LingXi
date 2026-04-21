import Foundation
import AppKit

@MainActor
final class ApplicationModule: SearchProviderModule {
    let moduleId = "default"
    let defaultProvider: ApplicationSearchProvider

    init() {
        self.defaultProvider = ApplicationSearchProvider()
    }

    func register(router: SearchRouter, settings: AppSettings) {
        // Default provider is already registered by SearchRouter init.
    }

    func applySettings(_ settings: AppSettings, router: SearchRouter) {
        router.setEnabled(settings.applicationSearchEnabled, forId: moduleId)
    }
}
