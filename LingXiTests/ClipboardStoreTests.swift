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

    // MARK: - Image support

    private func cleanupImageFiles(_ store: ClipboardStore) async {
        for item in await store.items where !item.imagePath.isEmpty {
            let path = ClipboardStore.imageDirectory.appendingPathComponent(item.imagePath).path
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func makePNGData(width: Int = 10, height: Int = 10) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func addImageEntryStoresItem() async {
        let store = await makeStore()
        let png = makePNGData()
        await store.addImageEntry(pngData: png, sourceApp: "Preview", sourceBundleId: "com.apple.Preview")
        let items = await store.items
        #expect(items.count == 1)
        #expect(items[0].contentType == .image)
        #expect(items[0].imageWidth == 10)
        #expect(items[0].imageHeight == 10)
        #expect(items[0].imageSize == png.count)
        #expect(items[0].sourceApp == "Preview")
        #expect(!items[0].imagePath.isEmpty)
        await cleanupImageFiles(store)
    }

    @Test func addImageEntryIncrementsVersion() async {
        let store = await makeStore()
        let v0 = await store.version
        await store.addImageEntry(pngData: makePNGData())
        let v1 = await store.version
        #expect(v1 > v0)
        await cleanupImageFiles(store)
    }

    @Test func tinyImageIsSkipped() async {
        let store = await makeStore()
        let tinyPNG = makePNGData(width: 3, height: 3)
        await store.addImageEntry(pngData: tinyPNG)
        let items = await store.items
        #expect(items.isEmpty)
    }

    @Test func imageAtMinSizeIsAccepted() async {
        let store = await makeStore()
        let png = makePNGData(width: 4, height: 4)
        await store.addImageEntry(pngData: png)
        let items = await store.items
        #expect(items.count == 1)
        await cleanupImageFiles(store)
    }

    @Test func duplicateImageIsSkipped() async {
        let store = await makeStore()
        let png = makePNGData()
        await store.addImageEntry(pngData: png)
        await store.addImageEntry(pngData: png)
        let items = await store.items
        #expect(items.count == 1)
        await cleanupImageFiles(store)
    }

    @Test func differentImagesAreNotDeduplicated() async {
        let store = await makeStore()
        let png1 = makePNGData(width: 10, height: 10)
        let png2 = makePNGData(width: 20, height: 20)
        await store.addImageEntry(pngData: png1)
        await store.addImageEntry(pngData: png2)
        let items = await store.items
        #expect(items.count == 2)
        await cleanupImageFiles(store)
    }

    @Test func deleteImageCleansUpFile() async {
        let store = await makeStore()
        await store.addImageEntry(pngData: makePNGData())
        let item = await store.items[0]
        let filePath = ClipboardStore.imageDirectory.appendingPathComponent(item.imagePath).path
        #expect(FileManager.default.fileExists(atPath: filePath))

        await store.delete(itemId: item.id)
        #expect(!FileManager.default.fileExists(atPath: filePath))
    }

    @Test func writeImageToClipboard() async {
        let store = await makeStore()
        let png = makePNGData()
        await store.addImageEntry(pngData: png)
        let itemId = await store.items[0].id
        let result = await store.writeToClipboard(itemId: itemId)
        #expect(result)

        let pb = NSPasteboard.general
        let pastedData = pb.data(forType: .png)
        #expect(pastedData == png)
        await cleanupImageFiles(store)
    }

    @Test func imageFilenameFormat() async {
        let store = await makeStore()
        await store.addImageEntry(pngData: makePNGData())
        let item = await store.items[0]
        let filename = item.imagePath
        #expect(filename.hasSuffix(".png"))
        let parts = filename.dropLast(4).split(separator: "_")
        #expect(parts.count == 2)
        #expect(Int(parts[0]) != nil)
        #expect(parts[1].count == 12)
        await cleanupImageFiles(store)
    }

    // MARK: - OCR

    private func makePNGDataWithText(_ text: String, width: Int = 200, height: Int = 200) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: NSPoint(x: 10, y: height / 2), withAttributes: attrs)
        image.unlockFocus()
        let tiffData = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiffData)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func ocrTriggeredForLargeImage() async {
        let store = await makeStore()
        let png = makePNGDataWithText("Hello World")
        await store.addImageEntry(pngData: png)
        let itemId = await store.items[0].id
        await store.awaitPendingOCR(itemId: itemId)

        let item = await store.items[0]
        #expect(!item.ocrText.isEmpty)
        await cleanupImageFiles(store)
    }

    @Test func ocrNotTriggeredForSmallImage() async {
        let store = await makeStore()
        let png = makePNGData(width: 50, height: 50)
        await store.addImageEntry(pngData: png)
        let item = await store.items[0]
        #expect(item.ocrText.isEmpty)
        await cleanupImageFiles(store)
    }

    @Test func ocrResultPersistedToDatabase() async {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent(
            "test_ocr_\(UUID().uuidString).db"
        ).path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var imagePath = ""
        do {
            let db = await DatabaseManager(databasePath: dbPath)
            let store = ClipboardStore(database: db)
            let png = makePNGDataWithText("Persist OCR")
            await store.addImageEntry(pngData: png)
            let itemId = await store.items[0].id
            await store.awaitPendingOCR(itemId: itemId)
            let item = await store.items[0]
            #expect(!item.ocrText.isEmpty)
            imagePath = item.imagePath
        }

        // Reload from database
        let db = await DatabaseManager(databasePath: dbPath)
        let store = ClipboardStore(database: db)
        // Trigger setupTask completion via a store operation
        await store.addTextEntry("trigger_setup")
        let items = await store.items.filter { $0.contentType == .image }
        #expect(items.count == 1)
        #expect(!items[0].ocrText.isEmpty)

        // Cleanup
        if !imagePath.isEmpty {
            let path = ClipboardStore.imageDirectory.appendingPathComponent(imagePath).path
            try? FileManager.default.removeItem(atPath: path)
        }
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
