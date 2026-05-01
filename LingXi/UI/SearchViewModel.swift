import Combine
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { onQueryChanged() }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0 {
        didSet {
            if oldValue != selectedIndex { pendingDeleteIndex = nil }
        }
    }
    @Published var activeModifiers: Set<ActionModifier> = [] {
        didSet {
            // Releasing Command cancels any pending delete confirmation.
            if oldValue.contains(.command) && !activeModifiers.contains(.command) {
                pendingDeleteIndex = nil
            }
        }
    }
    @Published private(set) var hasPreview: Bool = false
    @Published private(set) var pendingDeleteIndex: Int?

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
    var onSnippetPaste: ((String) -> Void)?
    var onCalculatorPaste: ((String) -> Void)?
    var onCommandExecute: ((SearchResult) -> Void)?
    var onDeleteItem: ((String) -> Void)?

    private var searchTask: Task<Void, Never>?
    private var generation: Int = 0
    /// Pre-boost scores; prevents boost from compounding across incremental merges.
    /// NOTE: Currently unused with batch search, retained for future incremental search support.
    private var originalScores: [String: Double] = [:]
    /// NOTE: Cache is unused with batch search (reset each query), retained for future incremental search support.
    private var cachedUsageCounts: [String: Int]?

    private var isSettingHistoryQuery = false

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

    // MARK: - Hover tracking

    /// Last point received from the results list's hover handler. `nil` means
    /// no baseline yet — the next hover event will establish one without
    /// changing selection. See `handleHover(at:rowHeight:)`.
    var lastHoverPoint: CGPoint?

    /// Clear the hover baseline so the next hover event is treated as the
    /// initial sample rather than real movement. Call this when the panel
    /// (re)opens so a stationary cursor can't hijack the default selection.
    func resetHoverTracking() {
        lastHoverPoint = nil
    }

    /// Update `selectedIndex` from a hover at `point` in a list of fixed-height
    /// rows. The first call after `resetHoverTracking()` only records the
    /// baseline; subsequent calls update selection only when `point` actually
    /// changed, ignoring re-fires caused by view re-layout.
    @discardableResult
    func handleHover(at point: CGPoint, rowHeight: CGFloat) -> Bool {
        guard let last = lastHoverPoint else {
            lastHoverPoint = point
            return false
        }
        guard point != last else { return false }
        lastHoverPoint = point
        let index = Int(point.y / rowHeight)
        guard results.indices.contains(index), selectedIndex != index else { return false }
        selectedIndex = index
        return true
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
        pendingDeleteIndex = nil

        // Check modifier actions first when modifiers are pressed
        if !modifiers.isEmpty, let modifierAction = selected.resolveModifierAction(for: modifiers) {
            let executed = modifierAction.action(selected)
            if executed { recordExecution(query: currentQuery, itemId: selected.itemId) }
            return executed
        }

        if let customAction = selected.action {
            let executed = customAction(selected)
            if executed { recordExecution(query: currentQuery, itemId: selected.itemId) }
            return executed
        }

        if selected.resultType == .command {
            onCommandExecute?(selected)
            recordExecution(query: currentQuery, itemId: selected.itemId)
            return true
        }

        let pasteHandler: ((String) -> Void)? = switch selected.resultType {
        case .clipboard: onClipboardPaste
        case .snippet: onSnippetPaste
        case .calculator: onCalculatorPaste
        default: nil
        }
        if let pasteHandler {
            // Calculator passes the raw numeric text via actionContext; other
            // result types route by itemId so providers can look up state.
            let payload = selected.resultType == .calculator
                ? selected.actionContext
                : selected.itemId
            pasteHandler(payload)
            recordExecution(query: currentQuery, itemId: selected.itemId)
            return true
        }

        guard let url = selected.url else { return false }

        let opened: Bool
        switch selected.resultType {
        case .application, .file, .systemSettings:
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

        // Plugin items with a delete_action use a two-press confirmation:
        // first press sets pendingDeleteIndex (UI shows "Delete?"),
        // second press on the same row executes the delete_action.
        if let pluginDelete = selected.deleteAction {
            if pendingDeleteIndex == selectedIndex {
                pendingDeleteIndex = nil
                let removedIndex = selectedIndex
                let executed = pluginDelete(selected)
                if executed, results.indices.contains(removedIndex) {
                    results.remove(at: removedIndex)
                    clampSelectedIndex()
                }
            } else {
                pendingDeleteIndex = selectedIndex
            }
            return
        }

        // Legacy single-press delete for clipboard items.
        guard selected.resultType == .clipboard else { return }
        onDeleteItem?(selected.itemId)
        results.remove(at: selectedIndex)
        clampSelectedIndex()
    }

    func tabComplete() async -> String? {
        guard results.indices.contains(selectedIndex) else { return nil }
        let selected = results[selectedIndex]
        return await router.tabComplete(rawQuery: query, selectedItem: selected)
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
        pendingDeleteIndex = nil
        // Results are about to change; re-establish the hover baseline so a
        // stationary cursor (common while typing) can't hijack the reset
        // selection when the list re-layouts.
        resetHoverTracking()

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

            let allResults = await router.search(rawQuery: currentQuery)
            guard generation == currentGeneration, !Task.isCancelled else { return }
            await applyResults(allResults, query: currentQuery, maxResults: maxResults)
        }
    }

    private func applyResults(_ incoming: [SearchResult], query: String, maxResults: Int) async {
        for result in incoming {
            originalScores[result.itemId] = max(originalScores[result.itemId, default: 0], result.score)
        }
        results = await applyUsageBoost(results: incoming, query: query, maxResults: maxResults)
        clampSelectedIndex()
    }

    private func applyUsageBoost(results: [SearchResult], query: String, maxResults: Int) async -> [SearchResult] {
        let itemIds = results.map(\.itemId)

        if cachedUsageCounts == nil {
            let fetched = await usageTracker.scores(query: query, itemIds: itemIds)
            var counts = fetched
            for id in itemIds where counts[id] == nil {
                counts[id] = 0
            }
            cachedUsageCounts = counts
        // NOTE: This branch is unreachable with batch search; retained for future incremental search support.
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
                if boosted[i].itemId.hasPrefix(ClipboardHistoryProvider.itemIdPrefix) { continue }
                if !boosted[i].usageBoostEnabled { continue }
                let original = originalScores[boosted[i].itemId] ?? boosted[i].score
                let count = usageCounts[boosted[i].itemId] ?? 0
                boosted[i].score = original + Double(min(count, usageBoostCap)) * usageBoostPerUse
            }
        }
        return boosted.sortedAndTruncated(maxResults: maxResults)
    }
}
