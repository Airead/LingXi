import AppKit
import Foundation

@MainActor
final class CalculatorModule: SearchProviderModule {
    let moduleId = "calculator"

    func register(router: SearchRouter, settings: AppSettings) {
        router.registerDefault(id: moduleId, provider: CalculatorProvider())
    }

    func bindEvents(to viewModel: SearchViewModel, context: PanelContext) {
        viewModel.onCalculatorPaste = { [weak context] rawValue in
            context?.pasteText(rawValue)
        }
    }
}
