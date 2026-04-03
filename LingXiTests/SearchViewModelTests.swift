import Testing
@testable import LingXi

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

    @Test func confirmDoesNotCrashWhenNoResults() {
        let router = SearchRouter(defaultProvider: MockSearchProvider())
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.confirm()
        #expect(vm.results.isEmpty)
    }

    @Test func confirmDoesNotCrashWithValidSelection() async {
        let vm = makeViewModel(query: "Safari")
        await Task.yield()
        #expect(vm.results.count == 1)
        vm.confirm()
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
}
