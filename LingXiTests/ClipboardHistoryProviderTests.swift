import Foundation
import Testing
@testable import LingXi

@MainActor
struct ClipboardHistoryProviderTests {

    private func makeProvider(capacity: Int = 200) async -> (ClipboardStore, ClipboardHistoryProvider) {
        let imageDir = makeTestTempDir(label: "ClipboardHistoryProviderTests")
        assertTestImageDirectory(imageDir)
        let store = ClipboardStore(
            database: await DatabaseManager(),
            capacity: capacity,
            imageDirectory: imageDir
        )
        let provider = ClipboardHistoryProvider(store: store)
        return (store, provider)
    }

    // MARK: - Empty query

    @Test func emptyQueryReturnsAllItems() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("first")
        await store.addTextEntry("second")
        let results = await provider.search(query: "")
        #expect(results.count == 2)
    }

    @Test func emptyQueryReturnsNewestFirst() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("older")
        await store.addTextEntry("newer")
        let results = await provider.search(query: "")
        #expect(results[0].name.contains("newer"))
        #expect(results[1].name.contains("older"))
    }

    @Test func emptyQueryOnEmptyStoreReturnsEmpty() async {
        let (_, provider) = await makeProvider()
        let results = await provider.search(query: "")
        #expect(results.isEmpty)
    }

    // MARK: - Fuzzy search

    @Test func fuzzySearchMatchesTextContent() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("hello world")
        await store.addTextEntry("goodbye moon")
        let results = await provider.search(query: "hello")
        #expect(results.count == 1)
        #expect(results[0].name.contains("hello"))
    }

    @Test func fuzzySearchMatchesSourceApp() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("some text", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        let results = await provider.search(query: "Safari")
        #expect(results.count == 1)
    }

    @Test func fuzzySearchNoMatchReturnsEmpty() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("hello world")
        let results = await provider.search(query: "zzzzz")
        #expect(results.isEmpty)
    }

    // MARK: - Result format

    @Test func resultTypeIsClipboard() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("test")
        let results = await provider.search(query: "")
        #expect(results[0].resultType == .clipboard)
    }

    @Test func resultItemIdHasClipboardPrefix() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("test")
        let results = await provider.search(query: "")
        #expect(results[0].itemId.hasPrefix("clipboard:"))
    }

    @Test func resultSubtitleContainsSourceApp() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("text", sourceApp: "Terminal", sourceBundleId: "com.apple.Terminal")
        let results = await provider.search(query: "")
        #expect(results[0].subtitle.contains("Terminal"))
    }

    @Test func resultSubtitleContainsRelativeTime() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("text")
        let results = await provider.search(query: "")
        #expect(results[0].subtitle.contains("just now"))
    }

    @Test func longTextIsTruncated() async {
        let (store, provider) = await makeProvider()
        let longText = String(repeating: "a", count: 200)
        await store.addTextEntry(longText)
        let results = await provider.search(query: "")
        #expect(results[0].name.count <= 80)
        #expect(results[0].name.hasSuffix("…"))
    }

    @Test func resultUrlIsNil() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("test")
        let results = await provider.search(query: "")
        #expect(results[0].url == nil)
    }

    // MARK: - Cache

    @Test func emptyQueryCacheReturnsConsistentResults() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("cached")
        let results1 = await provider.search(query: "")
        let results2 = await provider.search(query: "")
        #expect(results1.count == results2.count)
        #expect(results1[0].itemId == results2[0].itemId)
    }

    @Test func cacheInvalidatesOnVersionChange() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("first")
        let results1 = await provider.search(query: "")
        #expect(results1.count == 1)

        await store.addTextEntry("second")
        let results2 = await provider.search(query: "")
        #expect(results2.count == 2)
    }

    // MARK: - Relative time

    @Test func relativeTimeJustNow() {
        let now = Date().timeIntervalSince1970
        #expect(ClipboardHistoryProvider.relativeTime(from: now) == "just now")
    }

    @Test func relativeTimeMinutes() {
        let fiveMinAgo = Date().timeIntervalSince1970 - 300
        #expect(ClipboardHistoryProvider.relativeTime(from: fiveMinAgo) == "5m ago")
    }

    @Test func relativeTimeHours() {
        let twoHoursAgo = Date().timeIntervalSince1970 - 7200
        #expect(ClipboardHistoryProvider.relativeTime(from: twoHoursAgo) == "2h ago")
    }

    @Test func relativeTimeDays() {
        let threeDaysAgo = Date().timeIntervalSince1970 - 259200
        #expect(ClipboardHistoryProvider.relativeTime(from: threeDaysAgo) == "3d ago")
    }

    // MARK: - Truncated preview

    @Test func truncatedPreviewShortText() {
        #expect(ClipboardHistoryProvider.truncatedPreview("short", maxLength: 80) == "short")
    }

    @Test func truncatedPreviewReplacesNewlines() {
        #expect(ClipboardHistoryProvider.truncatedPreview("line1\nline2", maxLength: 80) == "line1 line2")
    }

    // MARK: - Preview data

    @Test func textResultHasTextPreviewData() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("hello preview")
        let results = await provider.search(query: "")
        guard case .text(let content) = results[0].previewData else {
            Issue.record("Expected .text preview data")
            return
        }
        #expect(content == "hello preview")
    }

    @Test func textPreviewContainsFullContent() async {
        let (store, provider) = await makeProvider()
        let longText = String(repeating: "a", count: 200)
        await store.addTextEntry(longText)
        let results = await provider.search(query: "")
        guard case .text(let content) = results[0].previewData else {
            Issue.record("Expected .text preview data")
            return
        }
        // Preview data should contain the full text, not the truncated name
        #expect(content.count == 200)
    }

    // MARK: - Formatted size

    @Test func formattedSizeBytes() {
        #expect(ClipboardHistoryProvider.formattedSize(512) == "512 B")
    }

    @Test func formattedSizeKilobytes() {
        #expect(ClipboardHistoryProvider.formattedSize(2048) == "2.0 KB")
    }

    @Test func formattedSizeMegabytes() {
        #expect(ClipboardHistoryProvider.formattedSize(2_097_152) == "2.0 MB")
    }
}
