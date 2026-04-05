import Foundation
import Testing
@testable import LingXi

struct QueryHistoryTests {

    private func makeHistory(capacity: Int = 100) async -> QueryHistory {
        QueryHistory(database: await DatabaseManager(), capacity: capacity)
    }

    // MARK: - Basic recording

    @Test func entriesEmptyByDefault() async {
        let history = await makeHistory()
        #expect(await history.entries().isEmpty)
    }

    @Test func recordAddsEntry() async {
        let history = await makeHistory()
        await history.record("safari")
        #expect(await history.entries() == ["safari"])
    }

    @Test func entriesOrderedMostRecentFirst() async {
        let history = await makeHistory()
        await history.record("first")
        await history.record("second")
        await history.record("third")
        #expect(await history.entries() == ["third", "second", "first"])
    }

    // MARK: - Deduplication

    @Test func duplicateMovesToMostRecent() async {
        let history = await makeHistory()
        await history.record("alpha")
        await history.record("beta")
        await history.record("alpha")
        let entries = await history.entries()
        #expect(entries == ["alpha", "beta"])
    }

    @Test func duplicateIsCasePreserving() async {
        let history = await makeHistory()
        await history.record("Safari")
        await history.record("chrome")
        await history.record("Safari")
        #expect(await history.entries() == ["Safari", "chrome"])
    }

    // MARK: - Capacity

    @Test func capacityLimitsEntries() async {
        let history = await makeHistory(capacity: 3)
        await history.record("a")
        await history.record("b")
        await history.record("c")
        await history.record("d")
        let entries = await history.entries()
        #expect(entries.count == 3)
        #expect(entries == ["d", "c", "b"])
    }

    @Test func capacityOneKeepsOnlyLatest() async {
        let history = await makeHistory(capacity: 1)
        await history.record("old")
        await history.record("new")
        #expect(await history.entries() == ["new"])
    }

    // MARK: - Edge cases

    @Test func emptyQueryIsIgnored() async {
        let history = await makeHistory()
        await history.record("")
        await history.record("   ")
        #expect(await history.entries().isEmpty)
    }

    @Test func whitespaceIsTrimmed() async {
        let history = await makeHistory()
        await history.record("  safari  ")
        #expect(await history.entries() == ["safari"])
    }

    @Test func trimmedDuplicateIsDeduped() async {
        let history = await makeHistory()
        await history.record("safari")
        await history.record("  safari  ")
        #expect(await history.entries().count == 1)
    }

    // MARK: - Clear

    @Test func clearAllRemovesAllEntries() async {
        let history = await makeHistory()
        await history.record("a")
        await history.record("b")
        await history.clearAll()
        #expect(await history.entries().isEmpty)
    }

    // MARK: - Persistence

    @Test func dataPersistsAcrossInstances() async {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_history_\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        do {
            let db = await DatabaseManager(databasePath: dbPath)
            let history = QueryHistory(database: db)
            await history.record("persisted query")
        }

        let db = await DatabaseManager(databasePath: dbPath)
        let history = QueryHistory(database: db)
        #expect(await history.entries() == ["persisted query"])
    }

    // MARK: - Shared database

    @Test func worksWithSharedDatabaseManager() async {
        let db = await DatabaseManager()
        let history = QueryHistory(database: db)
        await history.record("shared")
        #expect(await history.entries() == ["shared"])
    }

    @Test func coexistsWithUsageTrackerInSameDatabase() async {
        let db = await DatabaseManager()
        let history = QueryHistory(database: db)
        let tracker = UsageTracker(database: db)

        await history.record("test query")
        await tracker.record(query: "test", itemId: "com.test.app")

        #expect(await history.entries() == ["test query"])
        #expect(await tracker.score(query: "test", itemId: "com.test.app") == 1)
    }

    // MARK: - Thread safety

    @Test func concurrentAccessIsThreadSafe() async {
        let history = await makeHistory()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await history.record("query_\(i)")
                    _ = await history.entries()
                }
            }
        }

        #expect(await history.entries().count == 100)
    }
}
