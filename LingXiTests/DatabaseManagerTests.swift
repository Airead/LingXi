import Foundation
import Testing
@testable import LingXi

struct DatabaseManagerTests {

    private func makeDB() async -> DatabaseManager {
        await DatabaseManager()
    }

    // MARK: - Execute

    @Test func executeCreateTableAndInsert() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)")
        let ok = await db.execute("INSERT INTO test (name) VALUES (?)", bindings: [.text("hello")])
        #expect(ok)
    }

    @Test func executeReturnsFalseForInvalidSQL() async {
        let db = await makeDB()
        let ok = await db.execute("INVALID SQL")
        #expect(!ok)
    }

    // MARK: - Query

    @Test func queryReturnsInsertedRows() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")
        await db.execute("INSERT INTO items (value) VALUES (?)", bindings: [.text("a")])
        await db.execute("INSERT INTO items (value) VALUES (?)", bindings: [.text("b")])

        let values = await db.query("SELECT value FROM items ORDER BY id", map: { row in
            row.string(at: 0)
        })
        #expect(values == ["a", "b"])
    }

    @Test func queryReturnsEmptyForNoRows() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")

        let values = await db.query("SELECT value FROM items", map: { row in
            row.string(at: 0)
        })
        #expect(values.isEmpty)
    }

    @Test func queryWithBindings() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")
        await db.execute("INSERT INTO items (value) VALUES (?)", bindings: [.text("target")])
        await db.execute("INSERT INTO items (value) VALUES (?)", bindings: [.text("other")])

        let values = await db.query("SELECT value FROM items WHERE value = ?", bindings: [.text("target")], map: { row in
            row.string(at: 0)
        })
        #expect(values == ["target"])
    }

    // MARK: - Transaction

    @Test func transactionCommitsOnSuccess() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")

        let result = await db.transaction { tx in
            tx.execute("INSERT INTO items (value) VALUES (?)", bindings: [.text("a")])
            tx.execute("INSERT INTO items (value) VALUES (?)", bindings: [.text("b")])
            return true
        }
        #expect(result)

        let count = await db.query("SELECT COUNT(*) FROM items", map: { row in
            row.int(at: 0)
        })
        #expect(count == [2])
    }

    @Test func transactionRollsBackOnFailure() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")

        let result = await db.transaction { tx in
            tx.execute("INSERT INTO items (value) VALUES (?)", bindings: [.text("a")])
            return false
        }
        #expect(!result)

        let count = await db.query("SELECT COUNT(*) FROM items", map: { row in
            row.int(at: 0)
        })
        #expect(count == [0])
    }

    // MARK: - Typed bindings

    @Test func integerBindings() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE nums (id INTEGER PRIMARY KEY, value INTEGER)")
        await db.execute("INSERT INTO nums (value) VALUES (?)", bindings: [.integer(42)])
        await db.execute("INSERT INTO nums (value) VALUES (?)", bindings: [.integer(7)])

        let values = await db.query(
            "SELECT value FROM nums WHERE value > ?", bindings: [.integer(10)],
            map: { $0.int(at: 0) }
        )
        #expect(values == [42])
    }

    @Test func realBindings() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE measurements (id INTEGER PRIMARY KEY, value REAL)")
        await db.execute("INSERT INTO measurements (value) VALUES (?)", bindings: [.real(3.14)])

        let values = await db.query(
            "SELECT value FROM measurements", map: { $0.double(at: 0) }
        )
        #expect(values.count == 1)
        #expect(abs(values[0] - 3.14) < 0.001)
    }

    @Test func mixedBindings() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE mixed (id INTEGER PRIMARY KEY, name TEXT, score INTEGER, ratio REAL)")
        await db.execute(
            "INSERT INTO mixed (name, score, ratio) VALUES (?, ?, ?)",
            bindings: [.text("alice"), .integer(100), .real(0.95)]
        )

        let rows = await db.query("SELECT name, score, ratio FROM mixed", map: { row in
            (row.string(at: 0), row.int(at: 1), row.double(at: 2))
        })
        #expect(rows.count == 1)
        #expect(rows[0].0 == "alice")
        #expect(rows[0].1 == 100)
        #expect(abs(rows[0].2 - 0.95) < 0.001)
    }

    @Test func nullBindings() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE nullable (id INTEGER PRIMARY KEY, name TEXT)")
        await db.execute("INSERT INTO nullable (name) VALUES (?)", bindings: [.null])

        let values = await db.query("SELECT name FROM nullable", map: { $0.string(at: 0) })
        #expect(values == [""])
    }

    // MARK: - Thread safety

    @Test func concurrentAccessIsThreadSafe() async {
        let db = await makeDB()
        await db.execute("CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER)")
        await db.execute("INSERT INTO counter (id, value) VALUES (1, 0)")

        let iterations = 100
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await db.execute("UPDATE counter SET value = value + 1 WHERE id = 1")
                }
            }
        }

        let values = await db.query("SELECT value FROM counter WHERE id = 1", map: { row in
            row.int(at: 0)
        })
        #expect(values == [iterations])
    }

    // MARK: - Persistence

    @Test func dataPersistsAcrossInstances() async {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_db_\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        do {
            let db = await DatabaseManager(databasePath: dbPath)
            await db.execute("CREATE TABLE test (value TEXT)")
            await db.execute("INSERT INTO test (value) VALUES (?)", bindings: [.text("persisted")])
        }

        let db = await DatabaseManager(databasePath: dbPath)
        let values = await db.query("SELECT value FROM test", map: { row in
            row.string(at: 0)
        })
        #expect(values == ["persisted"])
    }
}
