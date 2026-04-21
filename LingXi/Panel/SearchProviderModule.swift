import Foundation
import AppKit

@MainActor
protocol SearchProviderModule {
    var moduleId: String { get }

    func register(router: SearchRouter, settings: AppSettings)
    func applySettings(_ settings: AppSettings, router: SearchRouter)
    func bindEvents(to viewModel: SearchViewModel, context: PanelContext)
    func start()
    func stop()
}

extension SearchProviderModule {
    func applySettings(_ settings: AppSettings, router: SearchRouter) {}
    func bindEvents(to viewModel: SearchViewModel, context: PanelContext) {}
    func start() {}
    func stop() {}
}
