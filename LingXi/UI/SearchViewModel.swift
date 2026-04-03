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
    private let usageTracker: UsageTracker
    private let debounceNanoseconds: UInt64
    private let usageBoostPerUse: Double = 1.0
    private let usageBoostCap: Int = 50
    private var searchTask: Task<Void, Never>?

    init(router: SearchRouter? = nil, workspace: WorkspaceOpening = NSWorkspace.shared,
         usageTracker: UsageTracker? = nil, debounceMilliseconds: Int = 0) {
        self.router = router ?? SearchRouter(defaultProvider: ApplicationSearchProvider())
        self.workspace = workspace
        self.usageTracker = usageTracker ?? UsageTracker()
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

        let opened: Bool
        switch selected.resultType {
        case .application:
            opened = workspace.open(url)
        default:
            opened = false
        }

        if opened {
            usageTracker.record(query: query, itemId: selected.itemId)
        }
        return opened
    }

    private func boostByUsage(results: [SearchResult], query: String) -> [SearchResult] {
        let usageCounts = usageTracker.scores(query: query, itemIds: results.map(\.itemId))
        guard !usageCounts.isEmpty else { return results }
        var boosted = results
        for i in boosted.indices {
            let count = usageCounts[boosted[i].itemId] ?? 0
            boosted[i].score += Double(min(count, usageBoostCap)) * usageBoostPerUse
        }
        boosted.sort { $0.score > $1.score }
        return boosted
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
            self.results = self.boostByUsage(results: searchResults, query: currentQuery)
            self.selectedIndex = 0
        }
    }
}
