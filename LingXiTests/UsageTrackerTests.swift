import Foundation
import Testing
@testable import LingXi

struct UsageTrackerTests {

    private func makeTracker() async -> UsageTracker {
        UsageTracker(database: await DatabaseManager())
    }

    // MARK: - Basic recording and scoring

    @Test func scoreReturnsZeroWithNoRecords() async {
        let tracker = await makeTracker()
        #expect(await tracker.score(query: "saf", itemId: "com.apple.Safari") == 0)
    }

    @Test func recordIncrementsScore() async {
        let tracker = await makeTracker()
        await tracker.record(query: "saf", itemId: "com.apple.Safari")
        #expect(await tracker.score(query: "saf", itemId: "com.apple.Safari") == 1)

        await tracker.record(query: "saf", itemId: "com.apple.Safari")
        await tracker.record(query: "saf", itemId: "com.apple.Safari")
        #expect(await tracker.score(query: "saf", itemId: "com.apple.Safari") == 3)
    }

    // MARK: - Prefix bucketing

    @Test func prefixUses3Characters() async {
        let tracker = await makeTracker()
        await tracker.record(query: "safari", itemId: "com.apple.Safari")
        // "saf" prefix should match
        #expect(await tracker.score(query: "saf", itemId: "com.apple.Safari") == 1)
        #expect(await tracker.score(query: "safari", itemId: "com.apple.Safari") == 1)
        // Different prefix should not match
        #expect(await tracker.score(query: "chr", itemId: "com.apple.Safari") == 0)
    }

    @Test func prefixIsCaseInsensitive() async {
        let tracker = await makeTracker()
        await tracker.record(query: "SAF", itemId: "com.apple.Safari")
        #expect(await tracker.score(query: "saf", itemId: "com.apple.Safari") == 1)
    }

    @Test func shortQueryUsesAvailableCharacters() async {
        let tracker = await makeTracker()
        await tracker.record(query: "sa", itemId: "com.apple.Safari")
        #expect(await tracker.score(query: "sa", itemId: "com.apple.Safari") == 1)
        // Different two-char prefix should not match
        #expect(await tracker.score(query: "sf", itemId: "com.apple.Safari") == 0)
    }

    // MARK: - Query-specific frequency

    @Test func frequencyIsQuerySpecific() async {
        let tracker = await makeTracker()
        await tracker.record(query: "chrome", itemId: "com.google.Chrome")
        await tracker.record(query: "chrome", itemId: "com.google.Chrome")
        // "chr" prefix has count 2
        #expect(await tracker.score(query: "chr", itemId: "com.google.Chrome") == 2)
        // "saf" prefix has count 0 for Chrome
        #expect(await tracker.score(query: "saf", itemId: "com.google.Chrome") == 0)
    }

    // MARK: - Global frequency

    @Test func recordAlsoTracksGlobalFrequency() async {
        let tracker = await makeTracker()
        await tracker.record(query: "saf", itemId: "com.apple.Safari")
        await tracker.record(query: "browse", itemId: "com.apple.Safari")
        // Global (empty query) should have count 2
        #expect(await tracker.score(query: "", itemId: "com.apple.Safari") == 2)
    }

    @Test func emptyQueryRecordsOnlyGlobal() async {
        let tracker = await makeTracker()
        await tracker.record(query: "", itemId: "com.apple.Safari")
        #expect(await tracker.score(query: "", itemId: "com.apple.Safari") == 1)
    }

    // MARK: - Clear

    @Test func clearAllRemovesAllRecords() async {
        let tracker = await makeTracker()
        await tracker.record(query: "saf", itemId: "com.apple.Safari")
        await tracker.record(query: "chr", itemId: "com.google.Chrome")
        await tracker.clearAll()
        #expect(await tracker.score(query: "saf", itemId: "com.apple.Safari") == 0)
        #expect(await tracker.score(query: "chr", itemId: "com.google.Chrome") == 0)
        #expect(await tracker.score(query: "", itemId: "com.apple.Safari") == 0)
    }

    // MARK: - Persistence

    @Test func dataPersistsAcrossInstances() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_usage_\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        do {
            let db = await DatabaseManager(databasePath: dbPath)
            let tracker = UsageTracker(database: db)
            await tracker.record(query: "saf", itemId: "com.apple.Safari")
        }

        let db = await DatabaseManager(databasePath: dbPath)
        let tracker = UsageTracker(database: db)
        #expect(await tracker.score(query: "saf", itemId: "com.apple.Safari") == 1)
    }

    // MARK: - Edge cases

    @Test func whitespaceTrimmedFromQuery() async {
        let tracker = await makeTracker()
        await tracker.record(query: "  saf  ", itemId: "com.apple.Safari")
        #expect(await tracker.score(query: "saf", itemId: "com.apple.Safari") == 1)
    }

    @Test func multipleItemsSamePrefix() async {
        let tracker = await makeTracker()
        await tracker.record(query: "cal", itemId: "com.apple.iCal")
        await tracker.record(query: "cal", itemId: "com.apple.iCal")
        await tracker.record(query: "cal", itemId: "com.apple.calculator")
        #expect(await tracker.score(query: "cal", itemId: "com.apple.iCal") == 2)
        #expect(await tracker.score(query: "cal", itemId: "com.apple.calculator") == 1)
    }

    // MARK: - Batch scores

    @Test func scoresReturnsEmptyForNoItems() async {
        let tracker = await makeTracker()
        #expect(await tracker.scores(query: "saf", itemIds: []).isEmpty)
    }

    @Test func scoresBatchReturnsCorrectCounts() async {
        let tracker = await makeTracker()
        await tracker.record(query: "cal", itemId: "com.apple.iCal")
        await tracker.record(query: "cal", itemId: "com.apple.iCal")
        await tracker.record(query: "cal", itemId: "com.apple.calculator")

        let result = await tracker.scores(query: "cal", itemIds: ["com.apple.iCal", "com.apple.calculator", "com.apple.Notes"])
        #expect(result["com.apple.iCal"] == 2)
        #expect(result["com.apple.calculator"] == 1)
        #expect(result["com.apple.Notes"] == nil)
    }

    @Test func scoresUsesQueryPrefix() async {
        let tracker = await makeTracker()
        await tracker.record(query: "safari", itemId: "com.apple.Safari")
        let result = await tracker.scores(query: "saf", itemIds: ["com.apple.Safari"])
        #expect(result["com.apple.Safari"] == 1)

        let empty = await tracker.scores(query: "chr", itemIds: ["com.apple.Safari"])
        #expect(empty.isEmpty)
    }

    // MARK: - Thread safety

    @Test func concurrentAccessIsThreadSafe() async {
        let tracker = await makeTracker()
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    await tracker.record(query: "saf", itemId: "com.apple.Safari")
                    _ = await tracker.score(query: "saf", itemId: "com.apple.Safari")
                    await tracker.record(query: "chr", itemId: "item.\(i)")
                    _ = await tracker.scores(query: "chr", itemIds: ["item.\(i)"])
                }
            }
        }

        #expect(await tracker.score(query: "saf", itemId: "com.apple.Safari") == iterations)
    }
}
