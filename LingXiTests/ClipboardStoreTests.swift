import AppKit
import Foundation
import Testing
@testable import LingXi

struct ClipboardStoreTests {

    private func makeStore(capacity: Int = 200) async -> ClipboardStore {
        ClipboardStore(database: await DatabaseManager(), capacity: capacity)
    }

    // MARK: - Basic text insertion

    @Test func itemsEmptyByDefault() async {
        let store = await makeStore()
        let items = await store.items
        #expect(items.isEmpty)
    }

    @Test func addTextEntryStoresItem() async {
        let store = await makeStore()
        await store.addTextEntry("hello world")
        let items = await store.items
        #expect(items.count == 1)
        #expect(items[0].textContent == "hello world")
        #expect(items[0].contentType == .text)
    }

    @Test func addTextEntryIncrementsVersion() async {
        let store = await makeStore()
        let v0 = await store.version
        await store.addTextEntry("test")
        let v1 = await store.version
        #expect(v1 > v0)
    }

    @Test func multipleEntriesOrderedNewestFirst() async {
        let store = await makeStore()
        await store.addTextEntry("first")
        await store.addTextEntry("second")
        await store.addTextEntry("third")
        let texts = await store.items.map(\.textContent)
        #expect(texts == ["third", "second", "first"])
    }

    @Test func storesSourceAppInfo() async {
        let store = await makeStore()
        await store.addTextEntry("text", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        let item = await store.items[0]
        #expect(item.sourceApp == "Safari")
        #expect(item.sourceBundleId == "com.apple.Safari")
    }

    // MARK: - Deduplication

    @Test func duplicateTextIsSkipped() async {
        let store = await makeStore()
        await store.addTextEntry("same text")
        await store.addTextEntry("same text")
        let items = await store.items
        #expect(items.count == 1)
    }

    @Test func differentTextIsNotDeduplicated() async {
        let store = await makeStore()
        await store.addTextEntry("text a")
        await store.addTextEntry("text b")
        let items = await store.items
        #expect(items.count == 2)
    }

    @Test func duplicateAfterDifferentEntryCreatesNewRecord() async {
        let store = await makeStore()
        await store.addTextEntry("alpha")
        await store.addTextEntry("beta")
        await store.addTextEntry("alpha")
        let items = await store.items
        #expect(items.count == 3)
        #expect(items[0].textContent == "alpha")
    }

    // MARK: - Large text

    @Test func oversizedTextIsSkipped() async {
        let store = await makeStore()
        let largeText = String(repeating: "x", count: 10241)
        await store.addTextEntry(largeText)
        let items = await store.items
        #expect(items.isEmpty)
    }

    @Test func textAtMaxLengthIsAccepted() async {
        let store = await makeStore()
        let text = String(repeating: "x", count: 10240)
        await store.addTextEntry(text)
        let items = await store.items
        #expect(items.count == 1)
    }

    // MARK: - Whitespace handling

    @Test func emptyTextIsIgnored() async {
        let store = await makeStore()
        await store.addTextEntry("")
        await store.addTextEntry("   ")
        await store.addTextEntry("\n\t")
        let items = await store.items
        #expect(items.isEmpty)
    }

    @Test func textIsTrimmed() async {
        let store = await makeStore()
        await store.addTextEntry("  hello  ")
        let items = await store.items
        #expect(items[0].textContent == "hello")
    }

    // MARK: - Delete

    @Test func deleteRemovesItem() async {
        let store = await makeStore()
        await store.addTextEntry("to delete")
        let itemId = await store.items[0].id
        await store.delete(itemId: itemId)
        let items = await store.items
        #expect(items.isEmpty)
    }

    @Test func deleteIncrementsVersion() async {
        let store = await makeStore()
        await store.addTextEntry("item")
        let v = await store.version
        let itemId = await store.items[0].id
        await store.delete(itemId: itemId)
        let v2 = await store.version
        #expect(v2 > v)
    }

    @Test func deleteNonexistentIdIsNoOp() async {
        let store = await makeStore()
        await store.addTextEntry("keep")
        await store.delete(itemId: 99999)
        let items = await store.items
        #expect(items.count == 1)
    }

    // MARK: - Capacity

    @Test func capacityEvictsOldest() async {
        let store = await makeStore(capacity: 3)
        await store.addTextEntry("a")
        await store.addTextEntry("b")
        await store.addTextEntry("c")
        await store.addTextEntry("d")
        let items = await store.items
        #expect(items.count == 3)
        let texts = items.map(\.textContent)
        #expect(texts == ["d", "c", "b"])
    }

    @Test func setCapacityTriggersEviction() async {
        let store = await makeStore(capacity: 100)
        await store.addTextEntry("a")
        await store.addTextEntry("b")
        await store.addTextEntry("c")
        await store.setCapacity(2)
        let items = await store.items
        #expect(items.count == 2)
        let texts = items.map(\.textContent)
        #expect(texts == ["c", "b"])
    }

    // MARK: - Write to clipboard

    @Test func writeToClipboardReturnsTrueForValidItem() async {
        let store = await makeStore()
        await store.addTextEntry("clipboard text")
        let itemId = await store.items[0].id
        let result = await store.writeToClipboard(itemId: itemId)
        #expect(result)
    }

    @Test func writeToClipboardReturnsFalseForInvalidId() async {
        let store = await makeStore()
        let result = await store.writeToClipboard(itemId: 99999)
        #expect(!result)
    }

    @Test func writeToClipboardSetsContent() async {
        let store = await makeStore()
        await store.addTextEntry("paste me")
        let itemId = await store.items[0].id
        await store.writeToClipboard(itemId: itemId)
        let pb = NSPasteboard.general
        #expect(pb.string(forType: .string) == "paste me")
    }

    @Test func writeToClipboardSetsConcealedType() async {
        let store = await makeStore()
        await store.addTextEntry("secret")
        let itemId = await store.items[0].id
        await store.writeToClipboard(itemId: itemId)
        let pb = NSPasteboard.general
        let types = pb.types?.map(\.rawValue) ?? []
        #expect(types.contains("org.nspasteboard.ConcealedType"))
        #expect(types.contains("org.nspasteboard.TransientType"))
    }

    // MARK: - Persistence

    @Test func dataPersistsAcrossInstances() async {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent(
            "test_clipboard_\(UUID().uuidString).db"
        ).path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        do {
            let db = await DatabaseManager(databasePath: dbPath)
            let store = ClipboardStore(database: db)
            await store.addTextEntry("persisted")
        }

        let db = await DatabaseManager(databasePath: dbPath)
        let store = ClipboardStore(database: db)
        // Wait for async setup (createTable + loadFromDatabase) to complete
        await store.addTextEntry("trigger_setup")
        // Remove the trigger entry and check persistence
        let items = await store.items.filter { $0.textContent == "persisted" }
        #expect(items.count == 1)
        #expect(items[0].textContent == "persisted")
    }

    // MARK: - Thread safety

    @Test func concurrentAccessIsThreadSafe() async {
        let store = await makeStore()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    await store.addTextEntry("entry_\(i)")
                    _ = await store.items
                    _ = await store.version
                }
            }
        }

        let items = await store.items
        #expect(items.count == 50)
    }
}
