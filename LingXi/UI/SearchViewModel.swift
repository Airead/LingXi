import Combine
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { onQueryChanged() }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0
    @Published var activeModifiers: Set<ActionModifier> = []
    @Published private(set) var hasPreview: Bool = false

    private struct HistoryBrowsing {
        let entries: [String]
        var index: Int
    }

    private var historyBrowsing: HistoryBrowsing?

    private let router: SearchRouter
    private let workspace: WorkspaceOpening
    private let usageTracker: UsageTracker
    private let queryHistory: QueryHistory
    private let debounceNanoseconds: UInt64
    private let usageBoostPerUse: Double = 1.0
    private let usageBoostCap: Int = 50
    var onClipboardPaste: ((String) -> Void)?
    var onDeleteItem: ((String) -> Void)?

    private var searchTask: Task<Void, Never>?
    private var generation: Int = 0
    /// Pre-boost scores; prevents boost from compounding across incremental merges.
    private var originalScores: [String: Double] = [:]
    private var cachedUsageCounts: [String: Int]?

    private var isSettingHistoryQuery = false
    private var lastReplacedGeneration: Int = -1

    init(router: SearchRouter? = nil, workspace: WorkspaceOpening = NSWorkspace.shared,
         database: DatabaseManager? = nil,
         debounceMilliseconds: Int = 0) async {
        let db: DatabaseManager
        if let database {
            db = database
        } else {
            db = await DatabaseManager()
        }
        self.router = router ?? SearchRouter(defaultProvider: ApplicationSearchProvider())
        self.workspace = workspace
        self.usageTracker = UsageTracker(database: db)
        self.queryHistory = QueryHistory(database: db)
        self.debounceNanoseconds = UInt64(debounceMilliseconds) * 1_000_000
    }

    func clear() {
        exitHistoryMode()
        query = ""
    }

    var historyIndex: Int? { historyBrowsing?.index }

    func moveUp() {
        if query.isEmpty || historyBrowsing != nil {
            Task { await historyUp() }
        } else {
            guard !results.isEmpty, selectedIndex > 0 else { return }
            selectedIndex -= 1
        }
    }

    func moveDown() {
        if historyBrowsing != nil {
            historyDown()
        } else {
            guard !results.isEmpty, selectedIndex < results.count - 1 else { return }
            selectedIndex += 1
        }
    }

    @discardableResult
    func confirm(modifiers: Set<ActionModifier> = []) -> Bool {
        guard results.indices.contains(selectedIndex) else { return false }
        let selected = results[selectedIndex]

        let currentQuery = query
        exitHistoryMode()

        if let modifierAction = selected.resolveModifierAction(for: modifiers) {
            let executed = modifierAction.action(selected)
            if executed { recordExecution(query: currentQuery, itemId: selected.itemId) }
            return executed
        }

        if selected.resultType == .clipboard {
            onClipboardPaste?(selected.itemId)
            recordExecution(query: currentQuery, itemId: selected.itemId)
            return true
        }

        guard let url = selected.url else { return false }

        let opened: Bool
        switch selected.resultType {
        case .application, .file:
            opened = workspace.open(url)
        case .bookmark:
            opened = openBookmark(url: url, bundleId: selected.openWithBundleId)
        default:
            opened = false
        }

        if opened { recordExecution(query: currentQuery, itemId: selected.itemId) }
        return opened
    }

    func deleteSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        let selected = results[selectedIndex]
        guard selected.resultType == .clipboard else { return }
        onDeleteItem?(selected.itemId)
        results.remove(at: selectedIndex)
        clampSelectedIndex()
    }

    private func clampSelectedIndex() {
        let clamped = min(selectedIndex, max(results.count - 1, 0))
        if selectedIndex != clamped {
            selectedIndex = clamped
        }
    }

    private func openBookmark(url: URL, bundleId: String?) -> Bool {
        if let bundleId,
           let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) {
            return workspace.open([url], withApplicationAt: appURL)
        }
        return workspace.open(url)
    }

    private func recordExecution(query: String, itemId: String) {
        Task {
            await usageTracker.record(query: query, itemId: itemId)
            await queryHistory.record(query)
        }
    }

    // MARK: - History browsing

    private func historyUp() async {
        if historyBrowsing == nil {
            let entries = await queryHistory.entries()
            guard !entries.isEmpty else { return }
            historyBrowsing = HistoryBrowsing(entries: entries, index: 0)
            setQueryFromHistory()
        } else if let browsing = historyBrowsing, browsing.index + 1 < browsing.entries.count {
            historyBrowsing?.index = browsing.index + 1
            setQueryFromHistory()
        }
    }

    private func historyDown() {
        guard let browsing = historyBrowsing else { return }
        if browsing.index - 1 >= 0 {
            historyBrowsing?.index = browsing.index - 1
            setQueryFromHistory()
        } else {
            exitHistoryMode()
            isSettingHistoryQuery = true
            defer { isSettingHistoryQuery = false }
            query = ""
        }
    }

    private func setQueryFromHistory() {
        guard let browsing = historyBrowsing else { return }
        isSettingHistoryQuery = true
        defer { isSettingHistoryQuery = false }
        query = browsing.entries[browsing.index]
    }

    private func exitHistoryMode() {
        historyBrowsing = nil
    }

    // MARK: - Query change handling

    private func onQueryChanged() {
        if !isSettingHistoryQuery && historyBrowsing != nil {
            exitHistoryMode()
        }
        hasPreview = router.hasPreviewProvider(for: query)
        filterResults()
    }

    private func filterResults() {
        searchTask?.cancel()
        generation += 1

        guard !query.isEmpty else {
            results = []
            selectedIndex = 0
            return
        }

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
                let proceed = await MainActor.run { self.generation == currentGeneration && !Task.isCancelled }
                guard proceed else { return }
                await self.mergeResults(providerResults, query: currentQuery, maxResults: maxResults)
            }
        }
    }

    private func mergeResults(_ incoming: [SearchResult], query: String, maxResults: Int) async {
        let isReplacement = (generation != lastReplacedGeneration)
        if isReplacement { lastReplacedGeneration = generation }

        let selectedItemId = isReplacement ? nil
            : (results.indices.contains(selectedIndex) ? results[selectedIndex].itemId : nil)

        for result in incoming {
            originalScores[result.itemId] = max(originalScores[result.itemId, default: 0], result.score)
        }

        var merged: [SearchResult]
        if isReplacement {
            merged = incoming
        } else {
            let existingIds = Set(results.map(\.itemId))
            merged = results
            for item in incoming where !existingIds.contains(item.itemId) {
                merged.append(item)
            }
        }
        results = await applyUsageBoost(results: merged, query: query, maxResults: maxResults)

        if let selectedItemId,
           let newIndex = results.firstIndex(where: { $0.itemId == selectedItemId }) {
            selectedIndex = newIndex
        } else {
            clampSelectedIndex()
        }
    }

    private func applyUsageBoost(results: [SearchResult], query: String, maxResults: Int) async -> [SearchResult] {
        let itemIds = results.map(\.itemId)

        if cachedUsageCounts == nil {
            let fetched = await usageTracker.scores(query: query, itemIds: itemIds)
            // Sentinel zero prevents the incremental branch from re-querying known-unused IDs
            var counts = fetched
            for id in itemIds where counts[id] == nil {
                counts[id] = 0
            }
            cachedUsageCounts = counts
        } else if var counts = cachedUsageCounts {
            let newIds = itemIds.filter { counts[$0] == nil }
            if !newIds.isEmpty {
                let fetched = await usageTracker.scores(query: query, itemIds: newIds)
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
