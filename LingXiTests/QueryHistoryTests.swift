import Foundation
import Testing
@testable import LingXi

struct QueryHistoryTests {

    private func makeHistory(capacity: Int = 100) -> QueryHistory {
        QueryHistory(capacity: capacity)
    }

    // MARK: - Basic recording

    @Test func entriesEmptyByDefault() {
        let history = makeHistory()
        #expect(history.entries().isEmpty)
    }

    @Test func recordAddsEntry() {
        let history = makeHistory()
        history.record("safari")
        #expect(history.entries() == ["safari"])
    }

    @Test func entriesOrderedMostRecentFirst() {
        let history = makeHistory()
        history.record("first")
        history.record("second")
        history.record("third")
        #expect(history.entries() == ["third", "second", "first"])
    }

    // MARK: - Deduplication

    @Test func duplicateMovesToMostRecent() {
        let history = makeHistory()
        history.record("alpha")
        history.record("beta")
        history.record("alpha")
        let entries = history.entries()
        #expect(entries == ["alpha", "beta"])
    }

    @Test func duplicateIsCasePreserving() {
        let history = makeHistory()
        history.record("Safari")
        history.record("chrome")
        history.record("Safari")
        #expect(history.entries() == ["Safari", "chrome"])
    }

    // MARK: - Capacity

    @Test func capacityLimitsEntries() {
        let history = makeHistory(capacity: 3)
        history.record("a")
        history.record("b")
        history.record("c")
        history.record("d")
        let entries = history.entries()
        #expect(entries.count == 3)
        #expect(entries == ["d", "c", "b"])
    }

    @Test func capacityOneKeepsOnlyLatest() {
        let history = makeHistory(capacity: 1)
        history.record("old")
        history.record("new")
        #expect(history.entries() == ["new"])
    }

    // MARK: - Edge cases

    @Test func emptyQueryIsIgnored() {
        let history = makeHistory()
        history.record("")
        history.record("   ")
        #expect(history.entries().isEmpty)
    }

    @Test func whitespaceIsTrimmed() {
        let history = makeHistory()
        history.record("  safari  ")
        #expect(history.entries() == ["safari"])
    }

    @Test func trimmedDuplicateIsDeduped() {
        let history = makeHistory()
        history.record("safari")
        history.record("  safari  ")
        #expect(history.entries().count == 1)
    }

    // MARK: - Clear

    @Test func clearAllRemovesAllEntries() {
        let history = makeHistory()
        history.record("a")
        history.record("b")
        history.clearAll()
        #expect(history.entries().isEmpty)
    }

    // MARK: - Persistence

    @Test func dataPersistsAcrossInstances() {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_history_\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        do {
            let db = DatabaseManager(databasePath: dbPath)
            let history = QueryHistory(database: db)
            history.record("persisted query")
        }

        let db = DatabaseManager(databasePath: dbPath)
        let history = QueryHistory(database: db)
        #expect(history.entries() == ["persisted query"])
    }

    // MARK: - Shared database

    @Test func worksWithSharedDatabaseManager() {
        let db = DatabaseManager()
        let history = QueryHistory(database: db)
        history.record("shared")
        #expect(history.entries() == ["shared"])
    }

    @Test func coexistsWithUsageTrackerInSameDatabase() {
        let db = DatabaseManager()
        let history = QueryHistory(database: db)
        let tracker = UsageTracker(database: db)

        history.record("test query")
        tracker.record(query: "test", itemId: "com.test.app")

        #expect(history.entries() == ["test query"])
        #expect(tracker.score(query: "test", itemId: "com.test.app") == 1)
    }

    // MARK: - Thread safety

    @Test func concurrentAccessIsThreadSafe() {
        let history = makeHistory()

        DispatchQueue.concurrentPerform(iterations: 100) { i in
            history.record("query_\(i)")
            _ = history.entries()
        }

        #expect(history.entries().count == 100)
    }
}
