import Foundation
import AppKit

@MainActor
final class SystemSettingsModule: SearchProviderModule {
    let moduleId = "system-settings"
    private let mixedModuleId = "system-settings-mixed"

    private let provider: SystemSettingsProvider
    private let mixedProvider: SystemSettingsMixedProvider

    init() {
        let source = SystemSettingsProvider()
        self.provider = source
        self.mixedProvider = SystemSettingsMixedProvider(source: source)
    }

    func register(router: SearchRouter, settings: AppSettings) {
        router.register(prefix: settings.systemSettingsSearchPrefix, id: moduleId, provider: provider)
        router.registerDefault(id: mixedModuleId, provider: mixedProvider)
    }

    func applySettings(_ settings: AppSettings, router: SearchRouter) {
        router.setEnabled(settings.systemSettingsSearchEnabled, forId: moduleId)
        router.setEnabled(settings.systemSettingsSearchEnabled, forId: mixedModuleId)
        router.updatePrefix(settings.systemSettingsSearchPrefix, forId: moduleId)
    }
}
