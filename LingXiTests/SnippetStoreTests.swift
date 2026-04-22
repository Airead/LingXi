import Foundation
import Testing
@testable import LingXi

@MainActor
struct SnippetStoreTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingXiSnippetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore() async throws -> (SnippetStore, URL) {
        let dir = try makeTempDir()
        let store = SnippetStore(directory: dir)
        return (store, dir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Frontmatter parsing

    @Test func parseFrontmatterWithKeyword() {
        let text = "---\nkeyword: \"@@email\"\n---\nuser@example.com"
        let (meta, body) = SnippetStore.parseFrontmatter(text)
        #expect(meta["keyword"] as? String == "@@email")
        #expect(body == "user@example.com")
    }

    @Test func parseFrontmatterNoFrontmatter() {
        let text = "just plain content"
        let (meta, body) = SnippetStore.parseFrontmatter(text)
        #expect(meta.isEmpty)
        #expect(body == "just plain content")
    }

    @Test func parseFrontmatterWithBoolean() {
        let text = "---\nrandom: true\nauto_expand: false\n---\ncontent"
        let (meta, _) = SnippetStore.parseFrontmatter(text)
        #expect(meta["random"] as? Bool == true)
        #expect(meta["auto_expand"] as? Bool == false)
    }

    @Test func parseFrontmatterWithSnippetsList() {
        let text = """
        ---
        snippets:
          - keyword: "ymd "
            content: "{date}"
          - keyword: "hms "
            content: "{time}"
            name: "current time"
        ---
        """
        let (meta, _) = SnippetStore.parseFrontmatter(text)
        let list = meta["snippets"] as? [[String: Any]]
        #expect(list?.count == 2)
        #expect(list?[0]["keyword"] as? String == "ymd ")
        #expect(list?[0]["content"] as? String == "{date}")
        #expect(list?[1]["name"] as? String == "current time")
    }

    // MARK: - Random sections

    @Test func splitRandomSections() {
        let body = "Hello!\n===\nHi there!\n===\nHey!"
        let sections = SnippetStore.splitRandomSections(body)
        #expect(sections.count == 3)
        #expect(sections[0] == "Hello!")
        #expect(sections[1] == "Hi there!")
        #expect(sections[2] == "Hey!")
    }

    @Test func splitRandomSectionsEscaped() {
        // A line whose stripped content is exactly \=== is unescaped to ===
        let body = "First\n\\===\n===\nSecond"
        let sections = SnippetStore.splitRandomSections(body)
        #expect(sections.count == 2)
        #expect(sections[0].contains("==="))
        #expect(!sections[0].contains("\\"))
    }

    // MARK: - Placeholder expansion

    @Test func expandDatePlaceholder() {
        let result = SnippetStore.expandPlaceholders("Today is {date}")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let expected = "Today is \(formatter.string(from: Date()))"
        #expect(result == expected)
    }

    @Test func expandEscapedBraces() {
        let result = SnippetStore.expandPlaceholders("Use {{date}} for dates")
        #expect(result == "Use {date} for dates")
    }

    // MARK: - File format

    @Test func formatSnippetFileSimple() {
        let result = SnippetStore.formatSnippetFile(keyword: "", content: "hello", autoExpand: true)
        #expect(result == "hello")
    }

    @Test func formatSnippetFileWithKeyword() {
        let result = SnippetStore.formatSnippetFile(keyword: ";;hi", content: "hello")
        #expect(result.contains("keyword: \";;hi\""))
        #expect(result.hasPrefix("---\n"))
        #expect(result.hasSuffix("hello"))
    }

    @Test func formatSnippetFileRandom() {
        let result = SnippetStore.formatSnippetFile(
            keyword: "thx", content: "", isRandom: true,
            variants: ["Thanks!", "Thank you!"]
        )
        #expect(result.contains("random: true"))
        #expect(result.contains("Thanks!\n===\nThank you!"))
    }

    // MARK: - Filename sanitization

    @Test func sanitizeFilename() {
        #expect(SnippetStore.sanitizeFilename("hello/world") == "hello_world")
        #expect(SnippetStore.sanitizeFilename("a<b>c") == "a_b_c")
        #expect(SnippetStore.sanitizeFilename("") == "snippet")
        #expect(SnippetStore.sanitizeFilename("normal") == "normal")
    }

    // MARK: - CRUD

    @Test func addAndRetrieveSnippet() async throws {
        let (store, dir) = try await makeStore()
        defer { cleanup(dir) }

        let ok = await store.add(name: "email", keyword: "@@em", content: "test@mail.com")
        #expect(ok)

        let all = await store.allSnippets()
        #expect(all.count == 1)
        #expect(all[0].name == "email")
        #expect(all[0].keyword == "@@em")
        #expect(all[0].content == "test@mail.com")
    }

    @Test func addDuplicateKeywordFails() async throws {
        let (store, dir) = try await makeStore()
        defer { cleanup(dir) }

        await store.add(name: "first", keyword: ";;dup", content: "a")
        let ok = await store.add(name: "second", keyword: ";;dup", content: "b")
        #expect(!ok)
    }

    @Test func removeSnippet() async throws {
        let (store, dir) = try await makeStore()
        defer { cleanup(dir) }

        await store.add(name: "temp", keyword: "", content: "to delete")
        let removed = await store.remove(name: "temp")
        #expect(removed)
        let all = await store.allSnippets()
        #expect(all.isEmpty)
    }

    @Test func findByKeyword() async throws {
        let (store, dir) = try await makeStore()
        defer { cleanup(dir) }

        await store.add(name: "email", keyword: "@@em", content: "test@mail.com")
        await store.add(name: "phone", keyword: "@@ph", content: "123-456")

        let found = await store.findByKeyword("@@ph")
        #expect(found?.name == "phone")
        #expect(await store.findByKeyword("@@nope") == nil)
    }

    @Test func categorySubdirectory() async throws {
        let (store, dir) = try await makeStore()
        defer { cleanup(dir) }

        await store.add(name: "sig", keyword: ";;sig", content: "Best regards", category: "Signatures")
        let all = await store.allSnippets()
        #expect(all.count == 1)
        #expect(all[0].category == "Signatures")

        let catDir = dir.appendingPathComponent("Signatures")
        #expect(FileManager.default.fileExists(atPath: catDir.path))
    }

    @Test func scanDirectoryLoadsFiles() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let content = "---\nkeyword: \";;hi\"\n---\nHello world"
        try content.write(to: dir.appendingPathComponent("greeting.md"), atomically: true, encoding: .utf8)

        let store = SnippetStore(directory: dir)
        let all = await store.allSnippets()
        #expect(all.count == 1)
        #expect(all[0].name == "greeting")
        #expect(all[0].keyword == ";;hi")
        #expect(all[0].content == "Hello world")
    }

    @Test func scanDirectoryWithRandomVariants() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let content = "---\nkeyword: \"thx\"\nrandom: true\n---\nThanks!\n===\nThank you!"
        try content.write(to: dir.appendingPathComponent("thanks.md"), atomically: true, encoding: .utf8)

        let store = SnippetStore(directory: dir)
        let all = await store.allSnippets()
        #expect(all.count == 1)
        #expect(all[0].isRandom)
        #expect(all[0].variants.count == 2)
    }

    @Test func scanDirectoryWithMultiSnippetFile() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let content = """
        ---
        snippets:
          - keyword: "ymd "
            content: "{date}"
          - keyword: "hms "
            content: "{time}"
        ---
        """
        try content.write(to: dir.appendingPathComponent("datetime.md"), atomically: true, encoding: .utf8)

        let store = SnippetStore(directory: dir)
        let all = await store.allSnippets()
        #expect(all.count == 2)
    }

    @Test func reloadDetectsChanges() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let store = SnippetStore(directory: dir)
        let empty = await store.allSnippets()
        #expect(empty.isEmpty)

        let content = "---\nkeyword: \";;new\"\n---\nNew snippet"
        try content.write(to: dir.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)

        await store.reload()
        let all = await store.allSnippets()
        #expect(all.count == 1)
    }

    // MARK: - Snippet resolved content

    @Test func snippetResolvedContentRaw() {
        let snippet = Snippet(
            name: "test", keyword: "", content: "{date}",
            category: "", filePath: "/tmp/test.md",
            autoExpand: true, raw: true, isRandom: false, variants: []
        )
        #expect(snippet.resolvedContent() == "{date}")
    }

    @Test func snippetResolvedContentExpanded() {
        let snippet = Snippet(
            name: "test", keyword: "", content: "{date}",
            category: "", filePath: "/tmp/test.md",
            autoExpand: true, raw: false, isRandom: false, variants: []
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        #expect(snippet.resolvedContent() == formatter.string(from: Date()))
    }

    @Test func snippetPreviewContentVariants() {
        let snippet = Snippet(
            name: "test", keyword: "", content: "A\n\nB",
            category: "", filePath: "/tmp/test.md",
            autoExpand: true, raw: false, isRandom: true,
            variants: ["A", "B"]
        )
        let preview = snippet.previewContent
        #expect(preview.contains("Variant 1"))
        #expect(preview.contains("Variant 2"))
    }
}
