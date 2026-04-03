import Foundation
import Testing
@testable import LingXi

private struct StubSearchProvider: SearchProvider {
    let results: [SearchResult]

    func search(query: String) async -> [SearchResult] {
        results
    }
}

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

private final class MockWorkspaceOpener: WorkspaceOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

@MainActor
private func waitUntil(timeout: Int = 1000, condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .milliseconds(timeout)
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(nanoseconds: 10 * 1_000_000)
    }
}

@MainActor
struct SearchViewModelTests {

    private func makeViewModel(query: String = "a") async -> SearchViewModel {
        let router = SearchRouter(defaultProvider: MockSearchProvider())
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
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

    @Test func moveDownDoesNothingWhenNoResults() {
        let router = SearchRouter(defaultProvider: MockSearchProvider())
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
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

    @Test func moveUpDoesNothingWhenNoResults() {
        let router = SearchRouter(defaultProvider: MockSearchProvider())
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.moveUp()
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - confirm

    @Test func confirmReturnsFalseWhenNoResults() {
        let router = SearchRouter(defaultProvider: MockSearchProvider())
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
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
        let vm = SearchViewModel(router: router, workspace: mockWorkspace, debounceMilliseconds: 0)
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
        let tracker = UsageTracker(databasePath: ":memory:")
        let mockWorkspace = MockWorkspaceOpener()
        let router = SearchRouter(defaultProvider: provider)
        let vm = SearchViewModel(router: router, workspace: mockWorkspace, usageTracker: tracker, debounceMilliseconds: 0)
        vm.query = "Test"
        await waitUntil { !vm.results.isEmpty }
        vm.confirm()
        #expect(tracker.score(query: "Test", itemId: "com.test.app") == 1)
    }

    @Test func usageBoostsResultOrder() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "app.first", icon: nil, name: "First", subtitle: "",
                         resultType: .application, url: nil, score: 80.0),
            SearchResult(itemId: "app.second", icon: nil, name: "Second", subtitle: "",
                         resultType: .application, url: nil, score: 50.0),
        ])
        let tracker = UsageTracker(databasePath: ":memory:")
        // Record enough usage for "Second" to overtake "First" (50 + 50 boost = 100 > 80)
        for _ in 0..<60 {
            tracker.record(query: "test", itemId: "app.second")
        }
        let router = SearchRouter(defaultProvider: provider)
        let vm = SearchViewModel(router: router, usageTracker: tracker, debounceMilliseconds: 0)
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
        let tracker = UsageTracker(databasePath: ":memory:")
        let router = SearchRouter(defaultProvider: provider)
        let vm = SearchViewModel(router: router, usageTracker: tracker, debounceMilliseconds: 0)
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
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
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
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
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
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
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
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.query = "test"
        await waitUntil { !vm.results.isEmpty }
        vm.query = ""
        await waitUntil { vm.results.isEmpty }
        #expect(vm.results.isEmpty)
        #expect(vm.selectedIndex == 0)
    }
}
