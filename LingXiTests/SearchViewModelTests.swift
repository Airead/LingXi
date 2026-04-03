import Foundation
import Testing
@testable import LingXi

private struct StubSearchProvider: SearchProvider {
    let results: [SearchResult]

    func search(query: String) async -> [SearchResult] {
        results
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
struct SearchViewModelTests {

    private func makeViewModel(query: String = "a") -> SearchViewModel {
        let router = SearchRouter(defaultProvider: MockSearchProvider())
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.query = query
        return vm
    }

    // MARK: - Selection reset on filter

    @Test func selectedIndexResetsOnQueryChange() async {
        let vm = makeViewModel(query: "m")
        await Task.yield()
        vm.moveDown()
        #expect(vm.selectedIndex > 0 || vm.results.count <= 1)
        vm.query = "s"
        await Task.yield()
        #expect(vm.selectedIndex == 0)
    }

    @Test func selectedIndexResetsWhenQueryCleared() async {
        let vm = makeViewModel(query: "m")
        await Task.yield()
        vm.moveDown()
        vm.query = ""
        await Task.yield()
        #expect(vm.selectedIndex == 0)
        #expect(vm.results.isEmpty)
    }

    // MARK: - moveDown

    @Test func moveDownIncrementsIndex() async {
        let vm = makeViewModel(query: "a")
        await Task.yield()
        #expect(vm.selectedIndex == 0)
        vm.moveDown()
        #expect(vm.selectedIndex == 1)
    }

    @Test func moveDownClampsAtBottom() async {
        let vm = makeViewModel(query: "a")
        await Task.yield()
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
        let vm = makeViewModel(query: "a")
        await Task.yield()
        vm.moveDown()
        vm.moveDown()
        vm.moveUp()
        #expect(vm.selectedIndex == 1)
    }

    @Test func moveUpClampsAtTop() async {
        let vm = makeViewModel(query: "a")
        await Task.yield()
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
        // MockSearchProvider returns results with url: nil
        let vm = makeViewModel(query: "Safari")
        await Task.yield()
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
        await Task.yield()
        #expect(vm.results.count == 1)
        #expect(vm.confirm() == true)
        #expect(mockWorkspace.openedURLs == [appURL])
    }

    // MARK: - clear

    @Test func clearResetsQueryAndResults() async {
        let vm = makeViewModel(query: "m")
        await Task.yield()
        vm.moveDown()
        vm.clear()
        await Task.yield()
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
        await Task.yield()
        vm.confirm()
        #expect(tracker.score(query: "Test", itemId: "com.test.app") == 1)
    }

    @Test func usageBoostsResultOrder() async {
        let provider = StubSearchProvider(results: [
            SearchResult(itemId: "app.first", icon: nil, name: "First", subtitle: "",
                         resultType: .application, url: nil, score: 100.0),
            SearchResult(itemId: "app.second", icon: nil, name: "Second", subtitle: "",
                         resultType: .application, url: nil, score: 50.0),
        ])
        let tracker = UsageTracker(databasePath: ":memory:")
        // Record enough usage for "Second" to overtake "First"
        for _ in 0..<60 {
            tracker.record(query: "test", itemId: "app.second")
        }
        let router = SearchRouter(defaultProvider: provider)
        let vm = SearchViewModel(router: router, usageTracker: tracker, debounceMilliseconds: 0)
        vm.query = "test"
        await Task.yield()
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
        await Task.yield()
        #expect(vm.results.first?.itemId == "app.first")
    }
}
