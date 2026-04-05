import Foundation
import Testing
@testable import LingXi

private final class DelayedStubProvider: SearchProvider, @unchecked Sendable {
    let results: [SearchResult]
    let delayMilliseconds: UInt64

    init(results: [SearchResult], delayMilliseconds: UInt64) {
        self.results = results
        self.delayMilliseconds = delayMilliseconds
    }

    func search(query: String) async -> [SearchResult] {
        try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
        guard !Task.isCancelled else { return [] }
        return results
    }
}

/// A provider that returns different results based on query, with optional delay.
private final class QueryAwareProvider: SearchProvider, @unchecked Sendable {
    let resultsByQuery: [String: [SearchResult]]
    let delayMilliseconds: UInt64

    init(resultsByQuery: [String: [SearchResult]], delayMilliseconds: UInt64 = 0) {
        self.resultsByQuery = resultsByQuery
        self.delayMilliseconds = delayMilliseconds
    }

    func search(query: String) async -> [SearchResult] {
        if delayMilliseconds > 0 {
            try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
            guard !Task.isCancelled else { return [] }
        }
        return resultsByQuery[query] ?? []
    }
}

@MainActor
struct SearchViewModelTests {

    private func makeViewModel(query: String = "a") async -> SearchViewModel {
        let router = SearchRouter(defaultProvider: MockSearchProvider())
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.query = query
        await waitUntil { !vm.results.isEmpty }
        return vm
    }

    // MARK: - Selection reset on filter

    @Test func selectedIndexResetsOnQueryChange() async {
        let vm = await makeViewModel(query: "m")
        if vm.results.count > 1 {
            vm.moveDown()
            #expect(vm.selectedIndex > 0)
        }
        vm.query = "s"
        await waitUntil { !vm.results.isEmpty }
        #expect(vm.selectedIndex == 0)
    }

    @Test func selectedIndexResetsWhenQueryCleared() async {
        let vm = await makeViewModel(query: "m")
        vm.moveDown()
        vm.query = ""
        await waitUntil { vm.results.isEmpty }
        #expect(vm.selectedIndex == 0)
        #expect(vm.results.isEmpty)
    }

    // MARK: - moveDown

    @Test func moveDownIncrementsIndex() async {
        let vm = await makeViewModel(query: "a")
        #expect(vm.selectedIndex == 0)
        vm.moveDown()
        #expect(vm.selectedIndex == 1)
    }

    @Test func moveDownClampsAtBottom() async {
        let vm = await makeViewModel(query: "a")
        let count = vm.results.count
        for _ in 0..<count + 5 {
            vm.moveDown()
        }
        #expect(vm.selectedIndex == count - 1)
    }

    @Test func moveDownDoesNothingWhenNoResults() async {
        let router = SearchRouter(defaultProvider: MockSearchProvider())
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.moveDown()
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - moveUp

    @Test func moveUpDecrementsIndex() async {
        let vm = await makeViewModel(query: "a")
        vm.moveDown()
        vm.moveDown()
        vm.moveUp()
        #expect(vm.selectedIndex == 1)
    }

    @Test func moveUpClampsAtTop() async {
        let vm = await makeViewModel(query: "a")
        vm.moveUp()
        #expect(vm.selectedIndex == 0)
    }

    @Test func moveUpDoesNothingWhenNoResults() async {
        let router = SearchRouter(defaultProvider: MockSearchProvider())
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.moveUp()
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - confirm

    @Test func confirmReturnsFalseWhenNoResults() async {
        let router = SearchRouter(defaultProvider: MockSearchProvider())
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        #expect(vm.confirm() == false)
        #expect(vm.results.isEmpty)
    }

    @Test func confirmReturnsFalseWhenSelectedResultHasNoURL() async {
        let vm = await makeViewModel(query: "Safari")
        #expect(vm.results.count == 1)
        #expect(vm.confirm() == false)
    }

    @Test func confirmReturnsTrueForApplicationWithURL() async {
        let appURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "com.test.app", icon: nil, name: "TestApp", subtitle: "Test",
                         resultType: .application, url: appURL, score: 1.0),
        ])
        let mockWorkspace = MockWorkspaceOpener()
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, workspace: mockWorkspace, debounceMilliseconds: 0)
        vm.query = "Test"
        await waitUntil { !vm.results.isEmpty }
        #expect(vm.results.count == 1)
        #expect(vm.confirm() == true)
        #expect(mockWorkspace.openedURLs == [appURL])
    }

    // MARK: - clear

    @Test func clearResetsQueryAndResults() async {
        let vm = await makeViewModel(query: "m")
        vm.moveDown()
        vm.clear()
        await waitUntil { vm.results.isEmpty }
        #expect(vm.query.isEmpty)
        #expect(vm.results.isEmpty)
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - Usage frequency integration

    @Test func confirmRecordsUsage() async {
        let appURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "com.test.app", icon: nil, name: "TestApp", subtitle: "Test",
                         resultType: .application, url: appURL, score: 1.0),
        ])
        let db = await DatabaseManager()
        let tracker = UsageTracker(database: db)
        let mockWorkspace = MockWorkspaceOpener()
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, workspace: mockWorkspace, database: db, debounceMilliseconds: 0)
        vm.query = "Test"
        await waitUntil { !vm.results.isEmpty }
        vm.confirm()
        // recordExecution is fire-and-forget, give it time to complete
        try? await Task.sleep(nanoseconds: 50 * 1_000_000)
        #expect(await tracker.score(query: "Test", itemId: "com.test.app") == 1)
    }

    @Test func usageBoostsResultOrder() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "app.first", icon: nil, name: "First", subtitle: "",
                         resultType: .application, url: nil, score: 80.0),
            SearchResult(itemId: "app.second", icon: nil, name: "Second", subtitle: "",
                         resultType: .application, url: nil, score: 50.0),
        ])
        let db = await DatabaseManager()
        let tracker = UsageTracker(database: db)
        // Record enough usage for "Second" to overtake "First" (50 + 50 boost = 100 > 80)
        for _ in 0..<60 {
            await tracker.record(query: "test", itemId: "app.second")
        }
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, database: db, debounceMilliseconds: 0)
        vm.query = "test"
        await waitUntil { vm.results.count == 2 }
        #expect(vm.results.first?.itemId == "app.second")
    }

    @Test func noUsageDataPreservesOriginalOrder() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "app.first", icon: nil, name: "First", subtitle: "",
                         resultType: .application, url: nil, score: 100.0),
            SearchResult(itemId: "app.second", icon: nil, name: "Second", subtitle: "",
                         resultType: .application, url: nil, score: 50.0),
        ])
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.query = "test"
        await waitUntil { vm.results.count == 2 }
        #expect(vm.results.first?.itemId == "app.first")
    }

    // MARK: - Incremental search tests

    @Test func incrementalMergeFromMultipleProviders() async {
        let fast = StubSearchProvider(results: [
            SearchResult(itemId: "fast1", icon: nil, name: "Fast1", subtitle: "",
                         resultType: .application, url: nil, score: 80),
        ])
        let slow = DelayedStubProvider(results: [
            SearchResult(itemId: "slow1", icon: nil, name: "Slow1", subtitle: "",
                         resultType: .application, url: nil, score: 90),
        ], delayMilliseconds: 100)

        let router = SearchRouter(defaultProvider: fast)
        router.registerDefault(id: "slow", provider: slow)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.query = "test"

        await waitUntil(timeout: 2000) { vm.results.count == 2 }
        #expect(vm.results[0].itemId == "slow1")
        #expect(vm.results[1].itemId == "fast1")
    }

    @Test func selectionStabilityOnIncrementalMerge() async {
        let fast = StubSearchProvider(results: [
            SearchResult(itemId: "item_a", icon: nil, name: "ItemA", subtitle: "",
                         resultType: .application, url: nil, score: 80),
            SearchResult(itemId: "item_b", icon: nil, name: "ItemB", subtitle: "",
                         resultType: .application, url: nil, score: 70),
        ])
        let slow = DelayedStubProvider(results: [
            SearchResult(itemId: "item_c", icon: nil, name: "ItemC", subtitle: "",
                         resultType: .application, url: nil, score: 90),
        ], delayMilliseconds: 300)

        let router = SearchRouter(defaultProvider: fast)
        router.registerDefault(id: "slow", provider: slow)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.query = "test"

        // Wait for fast provider
        await waitUntil { vm.results.count >= 2 }

        // User selects item_b (index 1)
        vm.moveDown()
        #expect(vm.selectedIndex == 1)
        let selectedBefore = vm.results[vm.selectedIndex].itemId

        // Wait for slow provider to merge
        await waitUntil(timeout: 2000) { vm.results.count == 3 }

        // item_b should still be selected
        #expect(vm.results.count == 3)
        let selectedAfter = vm.results[vm.selectedIndex].itemId
        #expect(selectedAfter == selectedBefore)
    }

    @Test func newQueryCancelsOldSearch() async {
        let provider = QueryAwareProvider(
            resultsByQuery: [
                "old": [SearchResult(itemId: "old_result", icon: nil, name: "Old", subtitle: "",
                                     resultType: .application, url: nil, score: 50)],
                "new": [SearchResult(itemId: "new_result", icon: nil, name: "New", subtitle: "",
                                     resultType: .application, url: nil, score: 50)],
            ],
            delayMilliseconds: 200
        )

        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.query = "old"

        // Quickly change query before old search completes
        try? await Task.sleep(nanoseconds: 20 * 1_000_000)
        vm.query = "new"

        // Wait for the new search to complete
        await waitUntil(timeout: 500) { !vm.results.isEmpty }

        // Only new results should appear
        let itemIds = vm.results.map(\.itemId)
        #expect(!itemIds.contains("old_result"))
        if !vm.results.isEmpty {
            #expect(itemIds.contains("new_result"))
        }
    }

    @Test func emptyQueryClearsResults() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "x", icon: nil, name: "X", subtitle: "",
                         resultType: .application, url: nil, score: 1),
        ])
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.query = "test"
        await waitUntil { !vm.results.isEmpty }
        vm.query = ""
        await waitUntil { vm.results.isEmpty }
        #expect(vm.results.isEmpty)
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - Query history browsing

    private func makeHistoryViewModel(
        historyEntries: [String],
        provider: SearchProvider? = nil
    ) async -> SearchViewModel {
        let db = await DatabaseManager()
        let history = QueryHistory(database: db)
        for entry in historyEntries.reversed() {
            await history.record(entry)
        }
        let router = SearchRouter(defaultProvider: provider ?? MockSearchProvider())
        return await SearchViewModel(
            router: router,
            database: db,
            debounceMilliseconds: 0
        )
    }

    @Test func moveUpOnEmptyQueryBrowsesHistory() async {
        let vm = await makeHistoryViewModel(historyEntries: ["recent", "older", "oldest"])
        #expect(vm.query.isEmpty)

        vm.moveUp()
        await waitUntil { vm.query == "recent" }
        #expect(vm.historyIndex == 0)

        vm.moveUp()
        await waitUntil { vm.query == "older" }
        #expect(vm.historyIndex == 1)

        vm.moveUp()
        await waitUntil { vm.query == "oldest" }
        #expect(vm.historyIndex == 2)
    }

    @Test func moveUpClampsAtOldestHistory() async {
        let vm = await makeHistoryViewModel(historyEntries: ["only"])
        vm.moveUp()
        await waitUntil { vm.query == "only" }
        vm.moveUp()
        await waitUntil { vm.historyIndex == 0 }
        #expect(vm.query == "only")
    }

    @Test func moveDownReturnsToMoreRecentHistory() async {
        let vm = await makeHistoryViewModel(historyEntries: ["recent", "older"])
        vm.moveUp()
        await waitUntil { vm.query == "recent" }
        vm.moveUp()
        await waitUntil { vm.query == "older" }
        vm.moveDown()
        #expect(vm.query == "recent")
        #expect(vm.historyIndex == 0)
    }

    @Test func moveDownPastRecentRestoresEmptyInput() async {
        let vm = await makeHistoryViewModel(historyEntries: ["recent"])
        vm.moveUp()
        await waitUntil { vm.query == "recent" }
        vm.moveDown()
        #expect(vm.query.isEmpty)
        #expect(vm.historyIndex == nil)
    }

    @Test func moveUpDoesNothingWhenNoHistory() async {
        let vm = await makeHistoryViewModel(historyEntries: [])
        vm.moveUp()
        // Give the internal Task a chance to run
        try? await Task.sleep(nanoseconds: 20 * 1_000_000)
        #expect(vm.query.isEmpty)
        #expect(vm.historyIndex == nil)
    }

    @Test func typingDuringHistoryExitsHistoryMode() async {
        let vm = await makeHistoryViewModel(historyEntries: ["recent", "older"])
        vm.moveUp()
        await waitUntil { vm.historyIndex != nil }

        vm.query = "user typed"
        #expect(vm.historyIndex == nil)
    }

    @Test func historyFillTriggersSearch() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "app1", icon: nil, name: "App", subtitle: "",
                         resultType: .application, url: nil, score: 1.0),
        ])
        let vm = await makeHistoryViewModel(historyEntries: ["App"], provider: provider)
        vm.moveUp()
        await waitUntil { vm.query == "App" }
        await waitUntil { !vm.results.isEmpty }
        #expect(!vm.results.isEmpty)
    }

    @Test func moveUpWithNonEmptyQueryNavigatesResults() async {
        let vm = await makeViewModel(query: "a")
        guard vm.results.count > 1 else { return }
        vm.moveDown()
        let indexAfterDown = vm.selectedIndex
        vm.moveUp()
        #expect(vm.selectedIndex == indexAfterDown - 1)
        #expect(vm.historyIndex == nil)
    }

    @Test func confirmRecordsQueryHistory() async {
        let appURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "com.test.app", icon: nil, name: "TestApp", subtitle: "Test",
                         resultType: .application, url: appURL, score: 1.0),
        ])
        let db = await DatabaseManager()
        let history = QueryHistory(database: db)
        let mockWorkspace = MockWorkspaceOpener()
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(
            router: router, workspace: mockWorkspace,
            database: db, debounceMilliseconds: 0
        )
        vm.query = "Test"
        await waitUntil { !vm.results.isEmpty }
        vm.confirm()
        // recordExecution is fire-and-forget, give it time to complete
        try? await Task.sleep(nanoseconds: 50 * 1_000_000)
        #expect(await history.entries() == ["Test"])
    }

    @Test func queryChangeDoesNotFlashEmptyResults() async {
        let providerA = StubSearchProvider(results: [
            SearchResult(itemId: "a1", icon: nil, name: "Alpha", subtitle: "",
                         resultType: .application, url: nil, score: 80),
        ])
        let router = SearchRouter(defaultProvider: providerA)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.query = "alpha"
        await waitUntil { !vm.results.isEmpty }
        #expect(vm.results.count == 1)

        // Changing query should NOT clear results to empty before new results arrive
        vm.query = "beta"
        // Immediately after setting query, results should still contain the old result
        #expect(!vm.results.isEmpty, "Results should not flash empty on query change")
    }

    // MARK: - Clipboard confirm

    @Test func confirmClipboardCallsPasteCallback() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "clipboard:42", icon: nil, name: "Hello", subtitle: "Safari",
                         resultType: .clipboard, url: nil, score: 1.0),
        ])
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        var pastedItemId: String?
        vm.onClipboardPaste = { itemId in pastedItemId = itemId }
        vm.query = "Hello"
        await waitUntil { !vm.results.isEmpty }
        let result = vm.confirm()
        #expect(result == true)
        #expect(pastedItemId == "clipboard:42")
    }

    @Test func confirmClipboardWithCommandUsesModifierAction() async {
        var copiedId: Int?
        let copyAction = ModifierAction(subtitle: "Copy to Clipboard") { result in
            if let id = ClipboardHistoryProvider.extractId(from: result.itemId) {
                copiedId = id
            }
            return true
        }
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "clipboard:7", icon: nil, name: "Text", subtitle: "Notes",
                         resultType: .clipboard, url: nil, score: 1.0,
                         modifierActions: [.command: copyAction]),
        ])
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        var pastedItemId: String?
        vm.onClipboardPaste = { itemId in pastedItemId = itemId }
        vm.query = "Text"
        await waitUntil { !vm.results.isEmpty }
        let result = vm.confirm(modifiers: [.command])
        #expect(result == true)
        #expect(copiedId == 7)
        #expect(pastedItemId == nil)
    }

    @Test func confirmClipboardPassesRawItemId() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "clipboard:invalid", icon: nil, name: "Bad", subtitle: "",
                         resultType: .clipboard, url: nil, score: 1.0),
        ])
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        var pastedItemId: String?
        vm.onClipboardPaste = { itemId in pastedItemId = itemId }
        vm.query = "Bad"
        await waitUntil { !vm.results.isEmpty }
        #expect(vm.confirm() == true)
        #expect(pastedItemId == "clipboard:invalid")
    }

    @Test func extractClipboardIdParsesValidId() {
        #expect(ClipboardHistoryProvider.extractId(from: "clipboard:123") == 123)
        #expect(ClipboardHistoryProvider.extractId(from: "clipboard:0") == 0)
        #expect(ClipboardHistoryProvider.extractId(from: "clipboard:abc") == nil)
        #expect(ClipboardHistoryProvider.extractId(from: "other:123") == nil)
        #expect(ClipboardHistoryProvider.extractId(from: "") == nil)
    }

    // MARK: - Delete

    @Test func deleteSelectedRemovesClipboardItem() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "clipboard:10", icon: nil, name: "First", subtitle: "",
                         resultType: .clipboard, url: nil, score: 2.0),
            SearchResult(itemId: "clipboard:20", icon: nil, name: "Second", subtitle: "",
                         resultType: .clipboard, url: nil, score: 1.0),
        ])
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        var deletedItemId: String?
        vm.onDeleteItem = { itemId in deletedItemId = itemId }
        vm.query = "clip"
        await waitUntil { vm.results.count == 2 }
        vm.selectedIndex = 0
        vm.deleteSelected()
        #expect(deletedItemId == "clipboard:10")
        #expect(vm.results.count == 1)
        #expect(vm.results[0].itemId == "clipboard:20")
        #expect(vm.selectedIndex == 0)
    }

    @Test func deleteSelectedAdjustsIndexWhenLastItem() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "clipboard:1", icon: nil, name: "A", subtitle: "",
                         resultType: .clipboard, url: nil, score: 2.0),
            SearchResult(itemId: "clipboard:2", icon: nil, name: "B", subtitle: "",
                         resultType: .clipboard, url: nil, score: 1.0),
        ])
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.onDeleteItem = { _ in }
        vm.query = "clip"
        await waitUntil { vm.results.count == 2 }
        vm.selectedIndex = 1
        vm.deleteSelected()
        #expect(vm.results.count == 1)
        #expect(vm.selectedIndex == 0)
    }

    @Test func deleteSelectedIgnoresNonClipboardItem() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "app:1", icon: nil, name: "App", subtitle: "",
                         resultType: .application, url: URL(string: "file:///app")!, score: 1.0),
        ])
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        var deletedItemId: String?
        vm.onDeleteItem = { itemId in deletedItemId = itemId }
        vm.query = "App"
        await waitUntil { !vm.results.isEmpty }
        vm.deleteSelected()
        #expect(deletedItemId == nil)
        #expect(vm.results.count == 1)
    }

    @Test func deleteSelectedLastRemainingItemClearsList() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "clipboard:99", icon: nil, name: "Only", subtitle: "",
                         resultType: .clipboard, url: nil, score: 1.0),
        ])
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.onDeleteItem = { _ in }
        vm.query = "Only"
        await waitUntil { !vm.results.isEmpty }
        vm.deleteSelected()
        #expect(vm.results.isEmpty)
        #expect(vm.selectedIndex == 0)
    }

    @Test func queryChangeReplacesResultsOnFirstMerge() async {
        let provider = QueryAwareProvider(
            resultsByQuery: [
                "old": [SearchResult(itemId: "old_item", icon: nil, name: "Old", subtitle: "",
                                     resultType: .application, url: nil, score: 50)],
                "new": [SearchResult(itemId: "new_item", icon: nil, name: "New", subtitle: "",
                                     resultType: .application, url: nil, score: 50)],
            ]
        )
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.query = "old"
        await waitUntil { !vm.results.isEmpty }
        #expect(vm.results.first?.itemId == "old_item")

        vm.query = "new"
        await waitUntil { vm.results.first?.itemId == "new_item" }
        // Old results should be fully replaced, not merged
        let itemIds = vm.results.map(\.itemId)
        #expect(!itemIds.contains("old_item"))
    }

    @Test func clearExitsHistoryMode() async {
        let vm = await makeHistoryViewModel(historyEntries: ["recent"])
        vm.moveUp()
        await waitUntil { vm.historyIndex != nil }
        vm.clear()
        #expect(vm.historyIndex == nil)
        #expect(vm.query.isEmpty)
    }
}
