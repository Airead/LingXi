import Foundation

nonisolated final class QueryHistory: Sendable {
    private let db: DatabaseManager
    private let capacity: Int
    private let setupTask: Task<Void, Never>

    init(database: DatabaseManager, capacity: Int = 100) {
        self.db = database
        self.capacity = capacity
        self.setupTask = Task {
            await database.execute("""
                CREATE TABLE IF NOT EXISTS query_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    query TEXT NOT NULL UNIQUE,
                    timestamp REAL NOT NULL
                )
                """)
        }
    }

    // MARK: - Public API

    func record(_ query: String) async {
        await setupTask.value
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let timestamp = Date().timeIntervalSince1970

        _ = await db.transaction { tx in
            tx.execute("DELETE FROM query_history WHERE query = ?", bindings: [trimmed])
            let ok = tx.execute(
                "INSERT INTO query_history (query, timestamp) VALUES (?, ?)",
                bindings: [trimmed, String(timestamp)]
            )
            tx.execute("""
                DELETE FROM query_history WHERE id NOT IN (
                    SELECT id FROM query_history ORDER BY timestamp DESC LIMIT ?
                )
                """, bindings: [String(self.capacity)])
            return ok
        }
    }

    func entries() async -> [String] {
        await setupTask.value
        return await db.query(
            "SELECT query FROM query_history ORDER BY timestamp DESC LIMIT ?",
            bindings: [String(capacity)]
        ) { row in
            row.string(at: 0)
        }
    }

    func clearAll() async {
        await setupTask.value
        await db.execute("DELETE FROM query_history")
    }
}
