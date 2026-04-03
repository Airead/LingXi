import Foundation
import Testing
@testable import LingXi

// MARK: - SearchResult.displaySubtitle tests

@MainActor
@Suite struct DisplaySubtitleTests {

    @Test func returnsOriginalSubtitleWhenNoModifiers() {
        let result = SearchResult(
            itemId: "test", icon: nil, name: "Test", subtitle: "Original",
            resultType: .application, url: nil, score: 1.0
        )
        #expect(result.displaySubtitle(for: []) == "Original")
    }

    @Test func returnsOriginalSubtitleWhenModifierNotDefined() {
        let result = SearchResult(
            itemId: "test", icon: nil, name: "Test", subtitle: "Original",
            resultType: .application, url: nil, score: 1.0,
            modifierActions: [
                .command: ModifierAction(subtitle: "Cmd Action") { _ in true },
            ]
        )
        #expect(result.displaySubtitle(for: [.option]) == "Original")
    }

    @Test func returnsModifierSubtitleWhenModifierActive() {
        let result = SearchResult(
            itemId: "test", icon: nil, name: "Test", subtitle: "Original",
            resultType: .application, url: nil, score: 1.0,
            modifierActions: [
                .command: ModifierAction(subtitle: "Show in Finder") { _ in true },
                .option: ModifierAction(subtitle: "Copy Path") { _ in true },
            ]
        )
        #expect(result.displaySubtitle(for: [.command]) == "Show in Finder")
        #expect(result.displaySubtitle(for: [.option]) == "Copy Path")
    }

    @Test func commandTakesPriorityOverOptionWhenBothActive() {
        let result = SearchResult(
            itemId: "test", icon: nil, name: "Test", subtitle: "Original",
            resultType: .application, url: nil, score: 1.0,
            modifierActions: [
                .command: ModifierAction(subtitle: "Cmd Action") { _ in true },
                .option: ModifierAction(subtitle: "Opt Action") { _ in true },
            ]
        )
        #expect(result.displaySubtitle(for: [.command, .option]) == "Cmd Action")
    }
}

// MARK: - SearchViewModel modifier confirm tests

@MainActor
@Suite struct ModifierConfirmTests {

    @Test func confirmWithModifierExecutesModifierAction() async {
        var modifierActionCalled = false
        let appURL = URL(fileURLWithPath: "/Applications/Test.app")
        let provider = StubSearchProvider(results: [
            SearchResult(
                itemId: "test.app", icon: nil, name: "Test", subtitle: "path",
                resultType: .application, url: appURL, score: 1.0,
                modifierActions: [
                    .command: ModifierAction(subtitle: "Show in Finder") { _ in
                        modifierActionCalled = true
                        return true
                    },
                ]
            ),
        ])
        let workspace = MockWorkspaceOpener()
        let router = SearchRouter(defaultProvider: provider)
        let vm = SearchViewModel(router: router, workspace: workspace, debounceMilliseconds: 0)
        vm.query = "Test"
        await waitUntil { !vm.results.isEmpty }

        let result = vm.confirm(modifiers: [.command])
        #expect(result == true)
        #expect(modifierActionCalled)
        #expect(workspace.openedURLs.isEmpty)
    }

    @Test func confirmWithUndefinedModifierFallsBackToDefault() async {
        let appURL = URL(fileURLWithPath: "/Applications/Test.app")
        let provider = StubSearchProvider(results: [
            SearchResult(
                itemId: "test.app", icon: nil, name: "Test", subtitle: "path",
                resultType: .application, url: appURL, score: 1.0,
                modifierActions: [
                    .command: ModifierAction(subtitle: "Show in Finder") { _ in true },
                ]
            ),
        ])
        let workspace = MockWorkspaceOpener()
        let router = SearchRouter(defaultProvider: provider)
        let vm = SearchViewModel(router: router, workspace: workspace, debounceMilliseconds: 0)
        vm.query = "Test"
        await waitUntil { !vm.results.isEmpty }

        let result = vm.confirm(modifiers: [.option])
        #expect(result == true)
        #expect(workspace.openedURLs == [appURL])
    }

    @Test func confirmWithEmptyModifiersExecutesDefaultAction() async {
        let appURL = URL(fileURLWithPath: "/Applications/Test.app")
        let provider = StubSearchProvider(results: [
            SearchResult(
                itemId: "test.app", icon: nil, name: "Test", subtitle: "path",
                resultType: .application, url: appURL, score: 1.0,
                modifierActions: [
                    .command: ModifierAction(subtitle: "Show in Finder") { _ in true },
                ]
            ),
        ])
        let workspace = MockWorkspaceOpener()
        let router = SearchRouter(defaultProvider: provider)
        let vm = SearchViewModel(router: router, workspace: workspace, debounceMilliseconds: 0)
        vm.query = "Test"
        await waitUntil { !vm.results.isEmpty }

        let result = vm.confirm(modifiers: [])
        #expect(result == true)
        #expect(workspace.openedURLs == [appURL])
    }

    @Test func confirmModifierActionRecordsUsage() async {
        let appURL = URL(fileURLWithPath: "/Applications/Test.app")
        let db = DatabaseManager()
        let tracker = UsageTracker(database: db)
        let provider = StubSearchProvider(results: [
            SearchResult(
                itemId: "test.app", icon: nil, name: "Test", subtitle: "path",
                resultType: .application, url: appURL, score: 1.0,
                modifierActions: [
                    .command: ModifierAction(subtitle: "Show in Finder") { _ in true },
                ]
            ),
        ])
        let workspace = MockWorkspaceOpener()
        let router = SearchRouter(defaultProvider: provider)
        let vm = SearchViewModel(router: router, workspace: workspace, database: db, debounceMilliseconds: 0)
        vm.query = "Test"
        await waitUntil { !vm.results.isEmpty }

        vm.confirm(modifiers: [.command])
        #expect(tracker.score(query: "Test", itemId: "test.app") == 1)
    }

    @Test func confirmReturnsFalseWhenNoResultsWithModifiers() {
        let router = SearchRouter(defaultProvider: StubSearchProvider(results: []))
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
        #expect(vm.confirm(modifiers: [.command]) == false)
    }
}

// MARK: - activeModifiers property tests

@MainActor
@Suite struct ActiveModifiersTests {

    @Test func activeModifiersDefaultsToEmpty() {
        let router = SearchRouter(defaultProvider: StubSearchProvider(results: []))
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
        #expect(vm.activeModifiers.isEmpty)
    }

    @Test func activeModifiersCanBeSet() {
        let router = SearchRouter(defaultProvider: StubSearchProvider(results: []))
        let vm = SearchViewModel(router: router, debounceMilliseconds: 0)
        vm.activeModifiers = [.command]
        #expect(vm.activeModifiers == [.command])
        vm.activeModifiers = []
        #expect(vm.activeModifiers.isEmpty)
    }
}
