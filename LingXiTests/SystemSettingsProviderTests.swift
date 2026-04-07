import Foundation
import Testing
@testable import LingXi

@MainActor
@Suite(.serialized)
struct SystemSettingsProviderTests {
    private static let provider = SystemSettingsProvider()

    // MARK: - Prefix mode (full search)

    @Test func emptyQueryReturnsPanels() async {
        let results = await Self.provider.search(query: "")
        #expect(!results.isEmpty)
        // Should return top-level panels sorted alphabetically
        let names = results.map(\.name)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func emptyQueryOnlyTopLevelPanels() async {
        let results = await Self.provider.search(query: "")
        // No sub-items (those with parentTitle) should appear
        for result in results {
            #expect(!result.subtitle.contains("\u{203a}"), "Expected no sub-items in empty query, got: \(result.subtitle)")
        }
    }

    @Test func searchByTitle() async {
        let results = await Self.provider.search(query: "Wi-Fi")
        #expect(results.contains { $0.name == "Wi-Fi" })
    }

    @Test func searchByKeyword() async {
        let results = await Self.provider.search(query: "dark mode")
        #expect(results.contains { $0.name == "Appearance" })
    }

    @Test func searchPrivacySubItem() async {
        let results = await Self.provider.search(query: "Camera")
        let privacy = results.first { $0.itemId == "system_settings:Privacy_Camera" }
        #expect(privacy != nil)
        #expect(privacy?.subtitle.contains("Privacy & Security") == true)
    }

    @Test func searchGeneralSubpanel() async {
        let results = await Self.provider.search(query: "Software Update")
        #expect(results.contains { $0.name == "Software Update" })
    }

    @Test func resultsHaveSystemSettingsType() async {
        let results = await Self.provider.search(query: "Bluetooth")
        for result in results {
            #expect(result.resultType == .systemSettings)
        }
    }

    @Test func resultsHaveURL() async {
        let results = await Self.provider.search(query: "Wi-Fi")
        for result in results {
            #expect(result.url != nil)
            #expect(result.url?.absoluteString.hasPrefix("x-apple.systempreferences:") == true)
        }
    }

    @Test func privacyAnchorURL() async {
        let results = await Self.provider.search(query: "Screen Recording")
        let item = results.first { $0.name == "Screen Recording" }
        #expect(item != nil)
        #expect(item?.url?.absoluteString.contains("?Privacy_ScreenCapture") == true)
    }

    @Test func iCloudSubIdURL() async {
        let results = await Self.provider.search(query: "iCloud")
        let item = results.first { $0.name == "iCloud" }
        #expect(item != nil)
        #expect(item?.url?.absoluteString.hasSuffix(":icloud") == true)
    }

    @Test func noMatchReturnsEmpty() async {
        let results = await Self.provider.search(query: "zzzzxyznonexistent")
        #expect(results.isEmpty)
    }

    @Test func caseInsensitiveSearch() async {
        let results = await Self.provider.search(query: "bluetooth")
        #expect(results.contains { $0.name == "Bluetooth" })
    }

    // MARK: - Mixed mode

    @Test func mixedEmptyQueryReturnsEmpty() async {
        let results = await Self.provider.searchMixed(query: "")
        #expect(results.isEmpty)
    }

    @Test func mixedResultsLimited() async {
        let results = await Self.provider.searchMixed(query: "a")
        #expect(results.count <= 5)
    }

    @Test func mixedReturnsResults() async {
        let results = await Self.provider.searchMixed(query: "Wi-Fi")
        #expect(results.contains { $0.name == "Wi-Fi" })
    }

    // MARK: - Data integrity

    @Test func allEntriesHaveUniqueItemIds() {
        let entries = SystemSettingsProvider.buildEntries()
        let ids = entries.map(\.itemId)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count, "Duplicate itemIds found")
    }

    @Test func allEntriesHaveValidURLs() {
        let entries = SystemSettingsProvider.buildEntries()
        for entry in entries {
            let url = entry.url
            #expect(url != nil, "Entry '\(entry.title)' has nil URL")
            #expect(url?.absoluteString.hasPrefix("x-apple.systempreferences:") == true)
        }
    }

    @Test func entryCountIsReasonable() {
        let entries = SystemSettingsProvider.buildEntries()
        // 36 top-level + 24 privacy + 11 general + 1 iCloud = 72
        #expect(entries.count >= 70)
        #expect(entries.count <= 100)
    }
}

@MainActor
@Suite(.serialized)
struct SystemSettingsMixedProviderTests {
    private static let source = SystemSettingsProvider()
    private static let provider = SystemSettingsMixedProvider(source: source)

    @Test func emptyQueryReturnsEmpty() async {
        let results = await Self.provider.search(query: "")
        #expect(results.isEmpty)
    }

    @Test func returnsLimitedResults() async {
        let results = await Self.provider.search(query: "a")
        #expect(results.count <= 5)
    }
}
