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

    @Test func fuzzySearchIgnoresSourceAppWithoutAtSign() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("some text", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        let results = await provider.search(query: "Safari")
        #expect(results.isEmpty)
    }

    @Test func fuzzySearchNoMatchReturnsEmpty() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("hello world")
        let results = await provider.search(query: "zzzzz")
        #expect(results.isEmpty)
    }

    @Test func fuzzySearchSortsByScoreDescending() async {
        let (store, provider) = await makeProvider()
        // Prefix match (score 100) should rank above substring match (score 50)
        await store.addTextEntry("world hello")  // substring match for "hello"
        await store.addTextEntry("hello world")  // prefix match for "hello"
        let results = await provider.search(query: "hello")
        #expect(results.count == 2)
        #expect(results[0].name.hasPrefix("hello"))
    }

    @Test func fuzzySearchTiebreaksByTimestamp() async {
        let (store, provider) = await makeProvider()
        // Two substring matches on "foo" — newer must come first.
        await store.addTextEntry("abc foo older")
        await store.addTextEntry("abc foo newer")
        let results = await provider.search(query: "foo")
        #expect(results.count == 2)
        #expect(results[0].name.contains("newer"))
        #expect(results[1].name.contains("older"))
    }

    // MARK: - @app filter

    @Test func atFilterMatchesSourceAppAfterSpace() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("foo", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        await store.addTextEntry("bar", sourceApp: "Terminal", sourceBundleId: "com.apple.Terminal")
        // Trailing space exits app-selection mode and enters content-filter mode.
        let results = await provider.search(query: "@Safari ")
        #expect(results.count == 1)
        #expect(results[0].name.contains("foo"))
    }

    @Test func atFilterWithContentQuery() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("foo bar", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        await store.addTextEntry("foo baz", sourceApp: "Terminal", sourceBundleId: "com.apple.Terminal")
        let results = await provider.search(query: "foo @Safari")
        #expect(results.count == 1)
        #expect(results[0].name.contains("bar"))
    }

    @Test func atFilterSupportsMultiWordAppName() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry(
            "page",
            sourceApp: "Google Chrome",
            sourceBundleId: "com.google.Chrome"
        )
        await store.addTextEntry("cmd", sourceApp: "Terminal", sourceBundleId: "com.apple.Terminal")
        let results = await provider.search(query: "@Google Chrome")
        #expect(results.count == 1)
        #expect(results[0].name.contains("page"))
    }

    @Test func atFilterAnywhereInQuery() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("foo bar", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        await store.addTextEntry("foo baz", sourceApp: "Terminal", sourceBundleId: "com.apple.Terminal")
        let results = await provider.search(query: "@Safari foo")
        #expect(results.count == 1)
        #expect(results[0].name.contains("bar"))
    }

    @Test func atFilterEmptyInContentModeIsIgnored() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("hello one")
        await store.addTextEntry("hello two")
        // `@` in the middle of content (not at start) with nothing after it:
        // app filter stays nil, falls back to plain content search.
        let results = await provider.search(query: "hello @")
        #expect(results.count == 2)
    }

    @Test func atFilterOnlyReturnsAllFromMatchingApp() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("a", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        await store.addTextEntry("b", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        await store.addTextEntry("c", sourceApp: "Terminal", sourceBundleId: "com.apple.Terminal")
        let results = await provider.search(query: "@Safari ")
        #expect(results.count == 2)
        // Newest first
        #expect(results[0].name.contains("b"))
        #expect(results[1].name.contains("a"))
    }

    // MARK: - Query parser

    @Test func parseQueryNoAtSign() {
        let parsed = ClipboardHistoryProvider.parseQuery("hello world", knownApps: [])
        #expect(parsed.content == "hello world")
        #expect(parsed.appFilter == nil)
    }

    @Test func parseQueryAppFilterOnly() {
        let parsed = ClipboardHistoryProvider.parseQuery("@Safari", knownApps: ["Safari"])
        #expect(parsed.content == "")
        #expect(parsed.appFilter == "Safari")
    }

    @Test func parseQueryContentAndAppFilter() {
        let parsed = ClipboardHistoryProvider.parseQuery("foo @Safari", knownApps: ["Safari"])
        #expect(parsed.content == "foo")
        #expect(parsed.appFilter == "Safari")
    }

    @Test func parseQueryAtFirstContentAfter() {
        let parsed = ClipboardHistoryProvider.parseQuery("@Safari foo", knownApps: ["Safari"])
        #expect(parsed.content == "foo")
        #expect(parsed.appFilter == "Safari")
    }

    @Test func parseQueryMultiWordAppName() {
        let parsed = ClipboardHistoryProvider.parseQuery(
            "@Google Chrome",
            knownApps: ["Google Chrome"]
        )
        #expect(parsed.content == "")
        #expect(parsed.appFilter == "Google Chrome")
    }

    @Test func parseQueryMultiWordAppNameWithTrailingContent() {
        let parsed = ClipboardHistoryProvider.parseQuery(
            "@Google Chrome feat",
            knownApps: ["Google Chrome"]
        )
        #expect(parsed.content == "feat")
        #expect(parsed.appFilter == "Google Chrome")
    }

    @Test func parseQueryFallsBackToFuzzyAppFilterWhenUnknown() {
        let parsed = ClipboardHistoryProvider.parseQuery("@tong", knownApps: ["TongYou"])
        #expect(parsed.content == "")
        #expect(parsed.appFilter == "tong")
    }

    @Test func parseQueryEmptyAtSign() {
        let parsed = ClipboardHistoryProvider.parseQuery("foo @", knownApps: [])
        #expect(parsed.content == "foo")
        #expect(parsed.appFilter == nil)
    }

    @Test func parseQuerySecondAtSignTerminatesAppFilter() {
        let parsed = ClipboardHistoryProvider.parseQuery(
            "@Safari @extra",
            knownApps: ["Safari"]
        )
        #expect(parsed.appFilter == "Safari")
    }

    // MARK: - App selection mode

    @Test func isAppSelectionModeDetectsAtPrefix() {
        #expect(ClipboardHistoryProvider.isAppSelectionMode("@"))
        #expect(ClipboardHistoryProvider.isAppSelectionMode("@sa"))
        #expect(ClipboardHistoryProvider.isAppSelectionMode("@Safari"))
    }

    @Test func isAppSelectionModeExitsOnSpace() {
        #expect(!ClipboardHistoryProvider.isAppSelectionMode("@Safari "))
        #expect(!ClipboardHistoryProvider.isAppSelectionMode("@Google Chrome"))
        #expect(!ClipboardHistoryProvider.isAppSelectionMode("foo @sa"))
        #expect(!ClipboardHistoryProvider.isAppSelectionMode(""))
        #expect(!ClipboardHistoryProvider.isAppSelectionMode("hello"))
    }

    @Test func atSignListsAllAppsByRecency() async {
        let (store, provider) = await makeProvider()
        // older Safari entry, then Terminal (now newest)
        await store.addTextEntry("a", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        await store.addTextEntry("b", sourceApp: "Terminal", sourceBundleId: "com.apple.Terminal")
        let results = await provider.search(query: "@")
        #expect(results.count == 2)
        #expect(results[0].name == "Terminal")
        #expect(results[1].name == "Safari")
        #expect(results[0].itemId == "clipboard:app:Terminal")
    }

    @Test func atSignFuzzyFiltersApps() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("a", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        await store.addTextEntry("b", sourceApp: "Terminal", sourceBundleId: "com.apple.Terminal")
        let results = await provider.search(query: "@saf")
        #expect(results.count == 1)
        #expect(results[0].name == "Safari")
    }

    @Test func atSignAppResultHasItemCountSubtitle() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("a", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        await store.addTextEntry("b", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        let results = await provider.search(query: "@")
        #expect(results[0].subtitle == "2 items")
    }

    @Test func atSignAppResultSingularSubtitle() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("a", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        let results = await provider.search(query: "@")
        #expect(results[0].subtitle == "1 item")
    }

    @Test func atSignAppResultHasTextPreview() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("hello world", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        await store.addTextEntry("second", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        let results = await provider.search(query: "@")
        guard case .text(let content) = results[0].previewData else {
            Issue.record("Expected .text preview")
            return
        }
        #expect(content.contains("Safari"))
        #expect(content.contains("hello world"))
        #expect(content.contains("second"))
    }

    @Test func atSignSkipsItemsWithoutSourceApp() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("a", sourceApp: "", sourceBundleId: "")
        await store.addTextEntry("b", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        let results = await provider.search(query: "@")
        #expect(results.count == 1)
        #expect(results[0].name == "Safari")
    }

    @Test func atSignAppResultActionReturnsFalse() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("a", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        let results = await provider.search(query: "@")
        let action = results[0].action
        #expect(action != nil)
        let returned = await MainActor.run { action!(results[0]) }
        #expect(returned == false)
    }

    // MARK: - Tab complete

    @Test func tabCompleteAppItemRewritesQuery() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("a", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        let results = await provider.search(query: "@saf")
        let completed = await provider.tabComplete(
            rawQuery: "cb @saf",
            strippedQuery: "@saf",
            selectedItem: results[0]
        )
        #expect(completed == "cb @Safari ")
    }

    @Test func tabCompleteAppItemPreservesMultiWordApp() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry(
            "p",
            sourceApp: "Google Chrome",
            sourceBundleId: "com.google.Chrome"
        )
        let results = await provider.search(query: "@goo")
        let completed = await provider.tabComplete(
            rawQuery: "cb @goo",
            strippedQuery: "@goo",
            selectedItem: results[0]
        )
        #expect(completed == "cb @Google Chrome ")
    }

    @Test func tabCompleteOnClipboardItemReturnsNil() async {
        let (store, provider) = await makeProvider()
        await store.addTextEntry("hello", sourceApp: "Safari", sourceBundleId: "com.apple.Safari")
        let results = await provider.search(query: "")
        let completed = await provider.tabComplete(
            rawQuery: "cb hello",
            strippedQuery: "hello",
            selectedItem: results[0]
        )
        #expect(completed == nil)
    }

    // MARK: - itemId helpers

    @Test func extractIdReturnsNilForAppItemId() {
        #expect(ClipboardHistoryProvider.extractId(from: "clipboard:app:Safari") == nil)
    }

    @Test func extractAppNameReturnsNilForRegularItemId() {
        #expect(ClipboardHistoryProvider.extractAppName(from: "clipboard:42") == nil)
    }

    @Test func extractAppNameReturnsAppForAppItemId() {
        #expect(ClipboardHistoryProvider.extractAppName(from: "clipboard:app:Google Chrome") == "Google Chrome")
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
