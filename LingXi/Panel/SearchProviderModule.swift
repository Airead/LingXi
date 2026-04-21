import Foundation
import AppKit

/// A modular unit that encapsulates a search provider, its settings, and event bindings.
/// Each module is independent; `PanelManager` does not know about concrete providers.
@MainActor
protocol SearchProviderModule {
    /// Unique identifier used when registering with `SearchRouter`.
    var moduleId: String { get }

    /// Register the module's provider(s) with the router.
    func register(router: SearchRouter, settings: AppSettings)

    /// React to settings changes (prefix, enabled/disabled, etc.).
    func applySettings(_ settings: AppSettings, router: SearchRouter)

    /// Wire user actions from the view model back to the module.
    func bindEvents(to viewModel: SearchViewModel, context: PanelContext)

    /// Called after `PanelManager` initialization.
    func start()

    /// Called when the panel manager is being torn down.
    func stop()
}

extension SearchProviderModule {
    func applySettings(_ settings: AppSettings, router: SearchRouter) {}
    func bindEvents(to viewModel: SearchViewModel, context: PanelContext) {}
    func start() {}
    func stop() {}
}
