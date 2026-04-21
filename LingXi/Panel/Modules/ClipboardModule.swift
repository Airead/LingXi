import Foundation
import AppKit

@MainActor
final class ClipboardModule: SearchProviderModule {
    let moduleId = "clipboard"

    private let store: ClipboardStore
    private let pluginManager: PluginService?

    init(store: ClipboardStore, pluginManager: PluginService? = nil) {
        self.store = store
        self.pluginManager = pluginManager
    }

    func register(router: SearchRouter, settings: AppSettings) {
        let copyHandler: @MainActor @Sendable (Int) -> Void = { [weak self] itemId in
            guard let self else { return }
            Task { await self.store.writeToClipboard(itemId: itemId) }
        }
        router.register(
            prefix: settings.clipboardSearchPrefix,
            id: moduleId,
            provider: ClipboardHistoryProvider(store: store, copyHandler: copyHandler)
        )
    }

    func applySettings(_ settings: AppSettings, router: SearchRouter) {
        router.setEnabled(settings.clipboardHistoryEnabled, forId: moduleId)
        router.updatePrefix(settings.clipboardSearchPrefix, forId: moduleId)

        let enabled = settings.clipboardHistoryEnabled
        let capacity = settings.clipboardHistoryCapacity
        Task {
            if enabled {
                await store.startMonitoring()
            } else {
                await store.stopMonitoring()
            }
            await store.setCapacity(capacity)
        }
    }

    func bindEvents(to viewModel: SearchViewModel, context: PanelContext) {
        if let pluginManager {
            let onClipboardChange: @Sendable (ClipboardItem) -> Void = { item in
                var data: [String: String] = [
                    "source_app": item.sourceApp,
                    "source_bundle_id": item.sourceBundleId,
                ]
                switch item.contentType {
                case .text:
                    data["text"] = item.textContent
                    data["type"] = "text"
                case .image:
                    data["type"] = "image"
                    data["image_path"] = item.imagePath
                }
                Task { @MainActor in
                    await pluginManager.dispatchEvent(name: PluginEvent.clipboardChange.rawValue, data: data)
                }
            }
            Task {
                await store.setOnChange(onClipboardChange)
            }
        }

        viewModel.onDeleteItem = { [weak self] itemId in
            guard let self, let id = ClipboardHistoryProvider.extractId(from: itemId) else { return }
            Task { await self.store.delete(itemId: id) }
        }

        viewModel.onClipboardPaste = { [weak self, weak context] itemId in
            guard let self, let id = ClipboardHistoryProvider.extractId(from: itemId) else { return }
            let target = context?.previousApp
            Task {
                await self.store.writeToClipboard(itemId: id)
                context?.pasteAndActivate(target: target)
            }
        }
    }

    func start() {}
    func stop() {}
}
