import Foundation
import Testing
@testable import LingXi

struct SnippetEditorViewModelTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingXiEditorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - SnippetStore.validateAndAdd

    @Test func validateAndAddSucceedsForValid() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        let result = await store.validateAndAdd(name: "new", category: "", keyword: "@@n", content: "hello")
        guard case .success = result else { Issue.record("Expected success"); return }
        let all = await store.allSnippets()
        #expect(all.count == 1)
    }

    @Test func validateAndAddDetectsFileExists() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        await store.add(name: "taken", keyword: "", content: "original")
        let result = await store.validateAndAdd(name: "taken", category: "", keyword: "", content: "different")
        guard case .failure(.fileExists("taken")) = result else { Issue.record("Expected fileExists"); return }
    }

    @Test func validateAndAddDetectsKeywordInUse() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        await store.add(name: "existing", keyword: "@@dup", content: "first")
        let result = await store.validateAndAdd(name: "new", category: "", keyword: "@@dup", content: "second")
        guard case .failure(.keywordInUse("@@dup")) = result else { Issue.record("Expected keywordInUse"); return }
    }

    @Test func validateAndAddDetectsContentDuplicates() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        await store.add(name: "existing", keyword: "", content: "same content")
        let result = await store.validateAndAdd(name: "new", category: "", keyword: "", content: "same content")
        guard case .failure(.contentDuplicates("existing")) = result else { Issue.record("Expected contentDuplicates"); return }
    }

    // MARK: - SnippetEditorViewModel validation

    @Test @MainActor func saveFailsWithEmptyName() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        var saved = false
        let vm = SnippetEditorViewModel(store: store, onSave: { _ in saved = true }, onCancel: {})
        vm.name = ""
        vm.content = "test"
        vm.save()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!saved)
        #expect(vm.errorMessage != nil)
    }

    @Test @MainActor func saveFailsWithEmptyNameAfterSlash() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        var saved = false
        let vm = SnippetEditorViewModel(store: store, onSave: { _ in saved = true }, onCancel: {})
        vm.name = "category/"
        vm.content = "test"
        vm.save()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!saved)
        #expect(vm.errorMessage != nil)
    }

    @Test @MainActor func saveSucceedsWithValidInput() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        var saved = false
        let vm = SnippetEditorViewModel(store: store, onSave: { _ in saved = true }, onCancel: {})
        vm.name = "mysnippet"
        vm.keyword = "@@ms"
        vm.content = "hello world"
        vm.save()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(saved)
        #expect(vm.errorMessage == nil)
        let all = await store.allSnippets()
        #expect(all.count == 1)
        #expect(all.first?.name == "mysnippet")
    }

    @Test @MainActor func saveFailsWithDuplicateKeyword() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        await store.add(name: "existing", keyword: "@@dup", content: "first")
        var saved = false
        let vm = SnippetEditorViewModel(store: store, onSave: { _ in saved = true }, onCancel: {})
        vm.name = "newsnippet"
        vm.keyword = "@@dup"
        vm.content = "second"
        vm.save()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!saved)
        #expect(vm.errorMessage?.contains("@@dup") == true)
    }

    @Test @MainActor func saveFailsWithDuplicateContent() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        await store.add(name: "existing", keyword: "", content: "same content")
        var saved = false
        let vm = SnippetEditorViewModel(store: store, onSave: { _ in saved = true }, onCancel: {})
        vm.name = "newsnippet"
        vm.keyword = ""
        vm.content = "same content"
        vm.save()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!saved)
        #expect(vm.errorMessage?.contains("existing") == true)
    }

    @Test @MainActor func saveFailsWithExistingFile() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        await store.add(name: "taken", keyword: "", content: "original")
        var saved = false
        let vm = SnippetEditorViewModel(store: store, onSave: { _ in saved = true }, onCancel: {})
        vm.name = "taken"
        vm.keyword = ""
        vm.content = "different content"
        vm.save()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!saved)
        #expect(vm.errorMessage?.contains("taken") == true)
    }

    @Test @MainActor func saveWithCategoryParsing() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        var savedCategory: String?
        let vm = SnippetEditorViewModel(store: store, onSave: { cat in savedCategory = cat }, onCancel: {})
        vm.name = "greetings/hello"
        vm.keyword = ""
        vm.content = "hello world"
        vm.save()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(savedCategory == "greetings")
        let all = await store.allSnippets()
        #expect(all.first?.category == "greetings")
        #expect(all.first?.name == "hello")
    }

    @Test @MainActor func initialCategoryPrefillsName() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SnippetStore(directory: dir)
        let vm = SnippetEditorViewModel(store: store, initialCategory: "emails", onSave: { _ in }, onCancel: {})
        #expect(vm.name.hasPrefix("emails/"))
    }
}
