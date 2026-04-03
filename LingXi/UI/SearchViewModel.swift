import Combine
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { filterResults() }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0

    private let router: SearchRouter
    private let workspace: WorkspaceOpening
    private let debounceNanoseconds: UInt64
    private var searchTask: Task<Void, Never>?

    init(router: SearchRouter? = nil, workspace: WorkspaceOpening = NSWorkspace.shared, debounceMilliseconds: Int = 0) {
        self.router = router ?? SearchRouter(defaultProvider: ApplicationSearchProvider())
        self.workspace = workspace
        self.debounceNanoseconds = UInt64(debounceMilliseconds) * 1_000_000
    }

    func clear() {
        query = ""
    }

    func moveUp() {
        guard !results.isEmpty, selectedIndex > 0 else { return }
        selectedIndex -= 1
    }

    func moveDown() {
        guard !results.isEmpty, selectedIndex < results.count - 1 else { return }
        selectedIndex += 1
    }

    @discardableResult
    func confirm() -> Bool {
        guard results.indices.contains(selectedIndex) else { return false }
        let selected = results[selectedIndex]

        guard let url = selected.url else { return false }

        switch selected.resultType {
        case .application:
            return workspace.open(url)
        default:
            return false
        }
    }

    private func filterResults() {
        searchTask?.cancel()

        guard !query.isEmpty else {
            results = []
            selectedIndex = 0
            return
        }

        let currentQuery = query
        searchTask = Task {
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
                guard !Task.isCancelled else { return }
            }
            let searchResults = await router.search(rawQuery: currentQuery)
            guard !Task.isCancelled, self.query == currentQuery else { return }
            self.results = searchResults
            self.selectedIndex = 0
        }
    }
}
