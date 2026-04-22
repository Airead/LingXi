import Foundation
import Testing
@testable import LingXi

@MainActor
struct SnippetSearchProviderTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingXiSnippetProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeProvider(dir: URL) async -> SnippetSearchProvider {
        let store = SnippetStore(directory: dir)
        return SnippetSearchProvider(store: store)
    }

    // MARK: - Empty query

    @Test func emptyQueryReturnsAllSnippets() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let content1 = "---\nkeyword: \";;hi\"\n---\nHello"
        let content2 = "---\nkeyword: \";;bye\"\n---\nGoodbye"
        try content1.write(to: dir.appendingPathComponent("hello.md"), atomically: true, encoding: .utf8)
        try content2.write(to: dir.appendingPathComponent("goodbye.md"), atomically: true, encoding: .utf8)

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "")
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.score == 50 })
    }

    @Test func emptyQueryNoSnippetsReturnsEmpty() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "")
        #expect(results.isEmpty)
    }

    // MARK: - Fuzzy search

    @Test func searchByName() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try "Hello world".write(to: dir.appendingPathComponent("greeting.md"), atomically: true, encoding: .utf8)
        try "Bye world".write(to: dir.appendingPathComponent("farewell.md"), atomically: true, encoding: .utf8)

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "greet")
        #expect(results.count == 1)
        #expect(results[0].name.contains("greeting"))
    }

    @Test func searchByKeyword() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let content = "---\nkeyword: \";;sig\"\n---\nBest regards"
        try content.write(to: dir.appendingPathComponent("signature.md"), atomically: true, encoding: .utf8)

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "sig")
        #expect(!results.isEmpty)
    }

    @Test func searchByContent() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try "user@example.com".write(to: dir.appendingPathComponent("email.md"), atomically: true, encoding: .utf8)

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "example")
        #expect(results.count == 1)
    }

    // MARK: - Result properties

    @Test func resultTypeIsSnippet() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try "content".write(to: dir.appendingPathComponent("test.md"), atomically: true, encoding: .utf8)

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "")
        #expect(results.first?.resultType == .snippet)
    }

    @Test func resultHasPreviewData() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try "preview content here".write(to: dir.appendingPathComponent("test.md"), atomically: true, encoding: .utf8)

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "")
        if case .text(let text) = results.first?.previewData {
            #expect(text == "preview content here")
        } else {
            Issue.record("Expected text preview data")
        }
    }

    @Test func resultTitleIncludesKeyword() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let content = "---\nkeyword: \";;hi\"\n---\nHello"
        try content.write(to: dir.appendingPathComponent("greeting.md"), atomically: true, encoding: .utf8)

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "")
        #expect(results.first?.name.contains("[;;hi]") == true)
    }

    @Test func resultTitleIncludesCategory() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let catDir = dir.appendingPathComponent("Emails")
        try FileManager.default.createDirectory(at: catDir, withIntermediateDirectories: true)
        try "content".write(to: catDir.appendingPathComponent("sig.md"), atomically: true, encoding: .utf8)

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "")
        #expect(results.first?.name.contains("Emails") == true)
    }

    @Test func resultItemIdFormat() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try "content".write(to: dir.appendingPathComponent("test.md"), atomically: true, encoding: .utf8)

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "")
        #expect(results.first?.itemId.hasPrefix("snippet:") == true)
    }

    @Test func resultHasModifierActions() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try "content".write(to: dir.appendingPathComponent("test.md"), atomically: true, encoding: .utf8)

        let provider = await makeProvider(dir: dir)
        let results = await provider.search(query: "")
        #expect(results.first?.modifierActions[.command] != nil)
        #expect(results.first?.modifierActions[.option] != nil)
    }

    // MARK: - Extract ID

    @Test func extractIdFromItemId() {
        #expect(SnippetSearchProvider.extractId(from: "snippet:test") == "test")
        #expect(SnippetSearchProvider.extractId(from: "snippet:cat/name") == "cat/name")
        #expect(SnippetSearchProvider.extractId(from: "clipboard:123") == nil)
    }
}
