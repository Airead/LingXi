import Foundation
import Testing
@testable import LingXi

struct CommandSearchProviderTests {
    private func makeProvider() -> CommandSearchProvider {
        CommandSearchProvider()
    }

    private func sampleEntry(
        name: String = "greet",
        title: String = "Say Hello",
        subtitle: String = "Greets the user",
        promoted: Bool = false
    ) -> CommandEntry {
        CommandEntry(
            name: name,
            title: title,
            subtitle: subtitle,
            action: { _ in },
            promoted: promoted
        )
    }

    // MARK: - Name validation

    @Test func validNames() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "reload-scripts"))
        try await provider.register(sampleEntry(name: "cc-sessions:clear-cache"))
        try await provider.register(sampleEntry(name: "reload_scripts"))
        try await provider.register(sampleEntry(name: "a"))
        try await provider.register(sampleEntry(name: "A1"))
    }

    @Test func invalidNameWithSpace() async {
        let provider = makeProvider()
        await #expect(throws: CommandError.self) {
            try await provider.register(sampleEntry(name: "has space"))
        }
    }

    @Test func invalidNameEmpty() async {
        let provider = makeProvider()
        await #expect(throws: CommandError.self) {
            try await provider.register(sampleEntry(name: ""))
        }
    }

    @Test func invalidNameStartsWithHyphen() async {
        let provider = makeProvider()
        await #expect(throws: CommandError.self) {
            try await provider.register(sampleEntry(name: "-bad"))
        }
    }

    @Test func duplicateRegistrationOverwrites() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "test", title: "Old Title"))
        try await provider.register(sampleEntry(name: "test", title: "New Title"))
        let results = await provider.search(query: "")
        #expect(results.count == 1)
        #expect(results[0].name == "New Title")
    }

    // MARK: - Search: empty query

    @Test func emptyQueryReturnsAllSortedByName() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "zebra", title: "Zebra"))
        try await provider.register(sampleEntry(name: "alpha", title: "Alpha"))
        try await provider.register(sampleEntry(name: "middle", title: "Middle"))
        let results = await provider.search(query: "")
        #expect(results.count == 3)
        #expect(results[0].name == "Alpha")
        #expect(results[1].name == "Middle")
        #expect(results[2].name == "Zebra")
        #expect(results.allSatisfy { $0.score == 50 })
    }

    // MARK: - Search: fuzzy match

    @Test func fuzzyMatchByTitle() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "greet", title: "Say Hello"))
        try await provider.register(sampleEntry(name: "quit", title: "Quit App"))
        let results = await provider.search(query: "hello")
        #expect(results.count == 1)
        #expect(results[0].name == "Say Hello")
    }

    @Test func fuzzyMatchByName() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "reload-scripts", title: "Reload All Scripts"))
        let results = await provider.search(query: "reload")
        #expect(results.count == 1)
        #expect(results[0].name == "Reload All Scripts")
    }

    @Test func noMatchReturnsEmpty() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "greet", title: "Say Hello"))
        let results = await provider.search(query: "zzzzz")
        #expect(results.isEmpty)
    }

    // MARK: - Search: args mode

    @Test func argsMode() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "greet", title: "Say Hello"))
        let results = await provider.search(query: "greet world")
        #expect(results.count == 1)
        #expect(results[0].actionContext == "world")
        #expect(results[0].score == 100)
    }

    @Test func argsModeEmptyArgs() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "greet", title: "Say Hello"))
        let results = await provider.search(query: "greet ")
        #expect(results.count == 1)
        #expect(results[0].actionContext == "")
    }

    @Test func argsModeNoExactMatch() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "greet", title: "Say Hello"))
        try await provider.register(sampleEntry(name: "greeting", title: "Extended Greeting"))
        // "gree world" — first word doesn't exactly match any command name
        let results = await provider.search(query: "gree world")
        // Falls back to fuzzy search, should not be args mode
        #expect(results.allSatisfy { $0.actionContext.isEmpty })
    }

    @Test func leadingSpaceTrimmed() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "greet", title: "Say Hello"))
        let results = await provider.search(query: "  greet world")
        #expect(results.count == 1)
        #expect(results[0].actionContext == "world")
    }

    // MARK: - Search: itemId format

    @Test func itemIdStartsWithCmdPrefix() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "test", title: "Test"))
        let results = await provider.search(query: "")
        #expect(results[0].itemId == "cmd:test")
    }

    // MARK: - Search: result type

    @Test func resultTypeIsCommand() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "test", title: "Test"))
        let results = await provider.search(query: "")
        #expect(results[0].resultType == .command)
    }

    // MARK: - Search: subtitle with args

    @Test func subtitleShowsArgsWhenPresent() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "greet", title: "Say Hello", subtitle: "Greets the user"))
        let results = await provider.search(query: "greet Alice")
        #expect(results[0].subtitle.contains("args: Alice"))
        #expect(results[0].subtitle.contains("Greets the user"))
    }

    @Test func subtitleShowsOnlyArgsWhenNoSubtitle() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "greet", title: "Say Hello", subtitle: ""))
        let results = await provider.search(query: "greet Alice")
        #expect(results[0].subtitle == "args: Alice")
    }

    // MARK: - Unregister / clear

    @Test func unregisterRemovesCommand() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "test", title: "Test"))
        await provider.unregister("test")
        let results = await provider.search(query: "")
        #expect(results.isEmpty)
    }

    @Test func unregisterNonexistentNoError() async {
        let provider = makeProvider()
        await provider.unregister("nonexistent")
    }

    @Test func clearRemovesAll() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "a", title: "A"))
        try await provider.register(sampleEntry(name: "b", title: "B"))
        await provider.clear()
        let results = await provider.search(query: "")
        #expect(results.isEmpty)
    }

    // MARK: - entry(for:)

    @Test func entryForValidItemId() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "test", title: "Test"))
        let entry = await provider.entry(for: "cmd:test")
        #expect(entry?.name == "test")
    }

    @Test func entryForInvalidItemId() async throws {
        let provider = makeProvider()
        let entry = await provider.entry(for: "snippet:test")
        #expect(entry == nil)
    }

    // MARK: - extractName

    @Test func extractName() {
        #expect(CommandSearchProvider.extractName(from: "cmd:test") == "test")
        #expect(CommandSearchProvider.extractName(from: "cmd:a:b") == "a:b")
        #expect(CommandSearchProvider.extractName(from: "snippet:test") == nil)
    }

    // MARK: - Promoted search

    @Test func promotedSearchOnlyReturnsPromoted() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "settings", title: "Open Settings", promoted: true))
        try await provider.register(sampleEntry(name: "quit", title: "Quit App", promoted: false))
        let results = await provider.promotedSearch(query: "settings")
        #expect(results.count == 1)
        #expect(results[0].name == "Open Settings")
    }

    @Test func promotedSearchEmptyQueryReturnsEmpty() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "settings", title: "Open Settings", promoted: true))
        let results = await provider.promotedSearch(query: "")
        #expect(results.isEmpty)
    }

    @Test func promotedSearchNoArgsMode() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "settings", title: "Open Settings", promoted: true))
        // "settings extra" in promoted search should be fuzzy, not args mode
        let results = await provider.promotedSearch(query: "settings extra")
        // Fuzzy match may or may not match, but actionContext should be empty
        #expect(results.allSatisfy { $0.actionContext.isEmpty })
    }

    @Test func promotedCommandAlsoAppearsInPrefixSearch() async throws {
        let provider = makeProvider()
        try await provider.register(sampleEntry(name: "settings", title: "Open Settings", promoted: true))
        let results = await provider.search(query: "settings")
        #expect(results.count == 1)
        #expect(results[0].name == "Open Settings")
    }
}

// MARK: - PromotedCommandSearchProvider tests

struct PromotedCommandSearchProviderTests {
    @Test func delegatesToPromotedSearch() async throws {
        let cmdProvider = CommandSearchProvider()
        try await cmdProvider.register(CommandEntry(
            name: "settings", title: "Open Settings",
            action: { _ in }, promoted: true
        ))
        try await cmdProvider.register(CommandEntry(
            name: "quit", title: "Quit App",
            action: { _ in }, promoted: false
        ))

        let promoted = PromotedCommandSearchProvider(commandProvider: cmdProvider)
        let results = await promoted.search(query: "settings")
        #expect(results.count == 1)
        #expect(results[0].name == "Open Settings")
    }

    @Test func emptyQueryReturnsEmpty() async throws {
        let cmdProvider = CommandSearchProvider()
        try await cmdProvider.register(CommandEntry(
            name: "settings", title: "Open Settings",
            action: { _ in }, promoted: true
        ))
        let promoted = PromotedCommandSearchProvider(commandProvider: cmdProvider)
        let results = await promoted.search(query: "")
        #expect(results.isEmpty)
    }
}
