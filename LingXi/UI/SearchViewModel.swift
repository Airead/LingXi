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
    private var generation: Int = 0
    /// Pre-boost scores; prevents boost from compounding across incremental merges.
    private var originalScores: [String: Double] = [:]
    private var cachedUsageCounts: [String: Int]?

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

    private func filterResults() {
        searchTask?.cancel()
        generation += 1

        guard !query.isEmpty else {
            results = []
            selectedIndex = 0
            return
        }

        results = []
        selectedIndex = 0
        originalScores = [:]
        cachedUsageCounts = nil

        let currentQuery = query
        let currentGeneration = generation
        let maxResults = router.maxResults

        searchTask = Task {
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
                guard !Task.isCancelled else { return }
            }

            await router.searchIncremental(rawQuery: currentQuery) { [weak self] _, providerResults in
                guard let self else { return }
                await MainActor.run {
                    guard self.generation == currentGeneration, !Task.isCancelled else { return }
                    self.mergeResults(providerResults, query: currentQuery, maxResults: maxResults)
                }
            }
        }
    }

    private func mergeResults(_ incoming: [SearchResult], query: String, maxResults: Int) {
        let selectedItemId = results.indices.contains(selectedIndex) ? results[selectedIndex].itemId : nil

        for result in incoming {
            if let existing = originalScores[result.itemId] {
                originalScores[result.itemId] = max(existing, result.score)
            } else {
                originalScores[result.itemId] = result.score
            }
        }

        // Dedup by itemId (keep existing over incoming), then append new items
        let existingIds = Set(results.map(\.itemId))
        var merged = results
        for item in incoming where !existingIds.contains(item.itemId) {
            merged.append(item)
        }
        results = applyUsageBoost(results: merged, query: query, maxResults: maxResults)

        if let selectedItemId,
           let newIndex = results.firstIndex(where: { $0.itemId == selectedItemId }) {
            selectedIndex = newIndex
        } else {
            selectedIndex = min(selectedIndex, max(results.count - 1, 0))
        }
    }

    private func applyUsageBoost(results: [SearchResult], query: String, maxResults: Int) -> [SearchResult] {
        let itemIds = results.map(\.itemId)

        if cachedUsageCounts == nil {
            let fetched = usageTracker.scores(query: query, itemIds: itemIds)
            // Sentinel zero prevents the incremental branch from re-querying known-unused IDs
            var counts = fetched
            for id in itemIds where counts[id] == nil {
                counts[id] = 0
            }
            cachedUsageCounts = counts
        } else if var counts = cachedUsageCounts {
            let newIds = itemIds.filter { counts[$0] == nil }
            if !newIds.isEmpty {
                let fetched = usageTracker.scores(query: query, itemIds: newIds)
                for id in newIds {
                    counts[id] = fetched[id] ?? 0
                }
                cachedUsageCounts = counts
            }
        }

        var boosted = results
        if let usageCounts = cachedUsageCounts, !usageCounts.isEmpty {
            for i in boosted.indices {
                let original = originalScores[boosted[i].itemId] ?? boosted[i].score
                let count = usageCounts[boosted[i].itemId] ?? 0
                boosted[i].score = original + Double(min(count, usageBoostCap)) * usageBoostPerUse
            }
        }
        return boosted.sortedAndTruncated(maxResults: maxResults)
    }
}
