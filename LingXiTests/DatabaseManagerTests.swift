import Foundation
import Testing
@testable import LingXi

struct DatabaseManagerTests {

    private func makeDB() -> DatabaseManager {
        DatabaseManager()
    }

    // MARK: - Execute

    @Test func executeCreateTableAndInsert() {
        let db = makeDB()
        db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)")
        let ok = db.execute("INSERT INTO test (name) VALUES (?)", bindings: ["hello"])
        #expect(ok)
    }

    @Test func executeReturnsFalseForInvalidSQL() {
        let db = makeDB()
        let ok = db.execute("INVALID SQL")
        #expect(!ok)
    }

    // MARK: - Query

    @Test func queryReturnsInsertedRows() {
        let db = makeDB()
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")
        db.execute("INSERT INTO items (value) VALUES (?)", bindings: ["a"])
        db.execute("INSERT INTO items (value) VALUES (?)", bindings: ["b"])

        let values = db.query("SELECT value FROM items ORDER BY id", map: { row in
            row.string(at: 0)
        })
        #expect(values == ["a", "b"])
    }

    @Test func queryReturnsEmptyForNoRows() {
        let db = makeDB()
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")

        let values = db.query("SELECT value FROM items", map: { row in
            row.string(at: 0)
        })
        #expect(values.isEmpty)
    }

    @Test func queryWithBindings() {
        let db = makeDB()
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")
        db.execute("INSERT INTO items (value) VALUES (?)", bindings: ["target"])
        db.execute("INSERT INTO items (value) VALUES (?)", bindings: ["other"])

        let values = db.query("SELECT value FROM items WHERE value = ?", bindings: ["target"], map: { row in
            row.string(at: 0)
        })
        #expect(values == ["target"])
    }

    // MARK: - Transaction

    @Test func transactionCommitsOnSuccess() {
        let db = makeDB()
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")

        let result = db.transaction { tx in
            tx.execute("INSERT INTO items (value) VALUES (?)", bindings: ["a"])
            tx.execute("INSERT INTO items (value) VALUES (?)", bindings: ["b"])
            return true
        }
        #expect(result)

        let count = db.query("SELECT COUNT(*) FROM items", map: { row in
            row.int(at: 0)
        })
        #expect(count == [2])
    }

    @Test func transactionRollsBackOnFailure() {
        let db = makeDB()
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")

        let result = db.transaction { tx in
            tx.execute("INSERT INTO items (value) VALUES (?)", bindings: ["a"])
            return false
        }
        #expect(!result)

        let count = db.query("SELECT COUNT(*) FROM items", map: { row in
            row.int(at: 0)
        })
        #expect(count == [0])
    }

    // MARK: - Thread safety

    @Test func concurrentAccessIsThreadSafe() {
        let db = makeDB()
        db.execute("CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER)")
        db.execute("INSERT INTO counter (id, value) VALUES (1, 0)")

        let iterations = 100
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            db.execute("UPDATE counter SET value = value + 1 WHERE id = 1")
        }

        let values = db.query("SELECT value FROM counter WHERE id = 1", map: { row in
            row.int(at: 0)
        })
        #expect(values == [iterations])
    }

    // MARK: - Persistence

    @Test func dataPersistsAcrossInstances() {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_db_\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        do {
            let db = DatabaseManager(databasePath: dbPath)
            db.execute("CREATE TABLE test (value TEXT)")
            db.execute("INSERT INTO test (value) VALUES (?)", bindings: ["persisted"])
        }

        let db = DatabaseManager(databasePath: dbPath)
        let values = db.query("SELECT value FROM test", map: { row in
            row.string(at: 0)
        })
        #expect(values == ["persisted"])
    }
}
