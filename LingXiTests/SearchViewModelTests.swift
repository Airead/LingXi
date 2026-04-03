import Testing
@testable import LingXi

@MainActor
struct SearchViewModelTests {

    private func makeViewModel(query: String = "a") -> SearchViewModel {
        let vm = SearchViewModel()
        vm.query = query
        return vm
    }

    // MARK: - Selection reset on filter

    @Test func selectedIndexResetsOnQueryChange() {
        let vm = makeViewModel(query: "m")
        // Move down then change query
        vm.moveDown()
        #expect(vm.selectedIndex > 0 || vm.results.count <= 1)
        vm.query = "s"
        #expect(vm.selectedIndex == 0)
    }

    @Test func selectedIndexResetsWhenQueryCleared() {
        let vm = makeViewModel(query: "m")
        vm.moveDown()
        vm.query = ""
        #expect(vm.selectedIndex == 0)
        #expect(vm.results.isEmpty)
    }

    // MARK: - moveDown

    @Test func moveDownIncrementsIndex() {
        let vm = makeViewModel(query: "a")
        #expect(vm.selectedIndex == 0)
        vm.moveDown()
        #expect(vm.selectedIndex == 1)
    }

    @Test func moveDownClampsAtBottom() {
        let vm = makeViewModel(query: "a")
        let count = vm.results.count
        for _ in 0..<count + 5 {
            vm.moveDown()
        }
        #expect(vm.selectedIndex == count - 1)
    }

    @Test func moveDownDoesNothingWhenNoResults() {
        let vm = SearchViewModel()
        vm.moveDown()
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - moveUp

    @Test func moveUpDecrementsIndex() {
        let vm = makeViewModel(query: "a")
        vm.moveDown()
        vm.moveDown()
        vm.moveUp()
        #expect(vm.selectedIndex == 1)
    }

    @Test func moveUpClampsAtTop() {
        let vm = makeViewModel(query: "a")
        vm.moveUp()
        #expect(vm.selectedIndex == 0)
    }

    @Test func moveUpDoesNothingWhenNoResults() {
        let vm = SearchViewModel()
        vm.moveUp()
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - confirm

    @Test func confirmDoesNotCrashWhenNoResults() {
        let vm = SearchViewModel()
        vm.confirm() // should not crash
        #expect(vm.results.isEmpty)
    }

    @Test func confirmDoesNotCrashWithValidSelection() {
        let vm = makeViewModel(query: "Safari")
        #expect(vm.results.count == 1)
        vm.confirm() // should print log without crashing
    }

    // MARK: - clear

    @Test func clearResetsQueryAndResults() {
        let vm = makeViewModel(query: "m")
        vm.moveDown()
        vm.clear()
        #expect(vm.query.isEmpty)
        #expect(vm.results.isEmpty)
        #expect(vm.selectedIndex == 0)
    }
}
