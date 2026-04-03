import Foundation
import Testing
@testable import LingXi

struct UsageTrackerTests {

    private func makeTracker() -> UsageTracker {
        // Use in-memory database for tests
        UsageTracker(databasePath: ":memory:")
    }

    // MARK: - Basic recording and scoring

    @Test func scoreReturnsZeroWithNoRecords() {
        let tracker = makeTracker()
        #expect(tracker.score(query: "saf", itemId: "com.apple.Safari") == 0)
    }

    @Test func recordIncrementsScore() {
        let tracker = makeTracker()
        tracker.record(query: "saf", itemId: "com.apple.Safari")
        #expect(tracker.score(query: "saf", itemId: "com.apple.Safari") == 1)

        tracker.record(query: "saf", itemId: "com.apple.Safari")
        tracker.record(query: "saf", itemId: "com.apple.Safari")
        #expect(tracker.score(query: "saf", itemId: "com.apple.Safari") == 3)
    }

    // MARK: - Prefix bucketing

    @Test func prefixUses3Characters() {
        let tracker = makeTracker()
        tracker.record(query: "safari", itemId: "com.apple.Safari")
        // "saf" prefix should match
        #expect(tracker.score(query: "saf", itemId: "com.apple.Safari") == 1)
        #expect(tracker.score(query: "safari", itemId: "com.apple.Safari") == 1)
        // Different prefix should not match
        #expect(tracker.score(query: "chr", itemId: "com.apple.Safari") == 0)
    }

    @Test func prefixIsCaseInsensitive() {
        let tracker = makeTracker()
        tracker.record(query: "SAF", itemId: "com.apple.Safari")
        #expect(tracker.score(query: "saf", itemId: "com.apple.Safari") == 1)
    }

    @Test func shortQueryUsesAvailableCharacters() {
        let tracker = makeTracker()
        tracker.record(query: "sa", itemId: "com.apple.Safari")
        #expect(tracker.score(query: "sa", itemId: "com.apple.Safari") == 1)
        // Different two-char prefix should not match
        #expect(tracker.score(query: "sf", itemId: "com.apple.Safari") == 0)
    }

    // MARK: - Query-specific frequency

    @Test func frequencyIsQuerySpecific() {
        let tracker = makeTracker()
        tracker.record(query: "chrome", itemId: "com.google.Chrome")
        tracker.record(query: "chrome", itemId: "com.google.Chrome")
        // "chr" prefix has count 2
        #expect(tracker.score(query: "chr", itemId: "com.google.Chrome") == 2)
        // "saf" prefix has count 0 for Chrome
        #expect(tracker.score(query: "saf", itemId: "com.google.Chrome") == 0)
    }

    // MARK: - Global frequency

    @Test func recordAlsoTracksGlobalFrequency() {
        let tracker = makeTracker()
        tracker.record(query: "saf", itemId: "com.apple.Safari")
        tracker.record(query: "browse", itemId: "com.apple.Safari")
        // Global (empty query) should have count 2
        #expect(tracker.score(query: "", itemId: "com.apple.Safari") == 2)
    }

    @Test func emptyQueryRecordsOnlyGlobal() {
        let tracker = makeTracker()
        tracker.record(query: "", itemId: "com.apple.Safari")
        #expect(tracker.score(query: "", itemId: "com.apple.Safari") == 1)
    }

    // MARK: - Clear

    @Test func clearAllRemovesAllRecords() {
        let tracker = makeTracker()
        tracker.record(query: "saf", itemId: "com.apple.Safari")
        tracker.record(query: "chr", itemId: "com.google.Chrome")
        tracker.clearAll()
        #expect(tracker.score(query: "saf", itemId: "com.apple.Safari") == 0)
        #expect(tracker.score(query: "chr", itemId: "com.google.Chrome") == 0)
        #expect(tracker.score(query: "", itemId: "com.apple.Safari") == 0)
    }

    // MARK: - Persistence

    @Test func dataPersistsAcrossInstances() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_usage_\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        do {
            let tracker = UsageTracker(databasePath: dbPath)
            tracker.record(query: "saf", itemId: "com.apple.Safari")
        }

        let tracker = UsageTracker(databasePath: dbPath)
        #expect(tracker.score(query: "saf", itemId: "com.apple.Safari") == 1)
    }

    // MARK: - Edge cases

    @Test func whitespaceTrimmedFromQuery() {
        let tracker = makeTracker()
        tracker.record(query: "  saf  ", itemId: "com.apple.Safari")
        #expect(tracker.score(query: "saf", itemId: "com.apple.Safari") == 1)
    }

    @Test func multipleItemsSamePrefix() {
        let tracker = makeTracker()
        tracker.record(query: "cal", itemId: "com.apple.iCal")
        tracker.record(query: "cal", itemId: "com.apple.iCal")
        tracker.record(query: "cal", itemId: "com.apple.calculator")
        #expect(tracker.score(query: "cal", itemId: "com.apple.iCal") == 2)
        #expect(tracker.score(query: "cal", itemId: "com.apple.calculator") == 1)
    }

    // MARK: - Batch scores

    @Test func scoresReturnsEmptyForNoItems() {
        let tracker = makeTracker()
        #expect(tracker.scores(query: "saf", itemIds: []).isEmpty)
    }

    @Test func scoresBatchReturnsCorrectCounts() {
        let tracker = makeTracker()
        tracker.record(query: "cal", itemId: "com.apple.iCal")
        tracker.record(query: "cal", itemId: "com.apple.iCal")
        tracker.record(query: "cal", itemId: "com.apple.calculator")

        let result = tracker.scores(query: "cal", itemIds: ["com.apple.iCal", "com.apple.calculator", "com.apple.Notes"])
        #expect(result["com.apple.iCal"] == 2)
        #expect(result["com.apple.calculator"] == 1)
        #expect(result["com.apple.Notes"] == nil)
    }

    @Test func scoresUsesQueryPrefix() {
        let tracker = makeTracker()
        tracker.record(query: "safari", itemId: "com.apple.Safari")
        let result = tracker.scores(query: "saf", itemIds: ["com.apple.Safari"])
        #expect(result["com.apple.Safari"] == 1)

        let empty = tracker.scores(query: "chr", itemIds: ["com.apple.Safari"])
        #expect(empty.isEmpty)
    }

    // MARK: - Thread safety

    @Test func concurrentAccessIsThreadSafe() async {
        let tracker = makeTracker()
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    tracker.record(query: "saf", itemId: "com.apple.Safari")
                    _ = tracker.score(query: "saf", itemId: "com.apple.Safari")
                    tracker.record(query: "chr", itemId: "item.\(i)")
                    _ = tracker.scores(query: "chr", itemIds: ["item.\(i)"])
                }
            }
        }

        #expect(tracker.score(query: "saf", itemId: "com.apple.Safari") == iterations)
    }
}
