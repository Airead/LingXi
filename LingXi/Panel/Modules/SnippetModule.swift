import Foundation
import AppKit

@MainActor
final class SnippetModule: SearchProviderModule {
    let moduleId = "snippet"

    private let store: SnippetStore
    private let expander: SnippetExpander
    private lazy var editorPanel = SnippetEditorPanel(store: store)

    init(store: SnippetStore) {
        self.store = store
        self.expander = SnippetExpander(store: store)
    }

    func register(router: SearchRouter, settings: AppSettings) {
        router.register(
            prefix: settings.snippetSearchPrefix,
            id: moduleId,
            provider: SnippetSearchProvider(store: store)
        )
    }

    func applySettings(_ settings: AppSettings, router: SearchRouter) {
        router.setEnabled(settings.snippetSearchEnabled, forId: moduleId)
        router.updatePrefix(settings.snippetSearchPrefix, forId: moduleId)

        setAutoExpandEnabled(settings.snippetAutoExpandEnabled)
    }

    func bindEvents(to viewModel: SearchViewModel, context: PanelContext) {
        viewModel.onSnippetPaste = { [weak self, weak context] itemId in
            guard let self, let id = SnippetSearchProvider.extractId(from: itemId) else { return }
            let target = context?.previousApp
            Task {
                guard let snippet = await self.store.findById(id) else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(snippet.resolvedContent(), forType: .string)
                context?.pasteAndActivate(target: target)
            }
        }
    }

    func start() {}

    func stop() {
        expander.stop()
    }

    func showEditor(onSaved: (() -> Void)? = nil) {
        editorPanel.show(onSaved: onSaved)
    }

    func isActive(in router: SearchRouter, for query: String) -> Bool {
        router.hasActiveProvider(id: moduleId, for: query)
    }

    func setAutoExpandEnabled(_ enabled: Bool) {
        if enabled {
            expander.start()
        } else {
            expander.stop()
        }
    }

    func suppress() {
        expander.suppress()
    }

    func resume() {
        expander.resume()
    }

    func refreshSnippets() async {
        await expander.refreshSnippets()
    }
}
