import Foundation

final class QueryHistory: Sendable {
    private let db: DatabaseManager
    private let capacity: Int

    init(database: DatabaseManager = DatabaseManager(), capacity: Int = 100) {
        self.db = database
        self.capacity = capacity
        createTable()
    }

    // MARK: - Public API

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let timestamp = Date().timeIntervalSince1970

        _ = db.transaction { tx in
            tx.execute("DELETE FROM query_history WHERE query = ?", bindings: [trimmed])
            let ok = tx.execute(
                "INSERT INTO query_history (query, timestamp) VALUES (?, ?)",
                bindings: [trimmed, String(timestamp)]
            )
            tx.execute("""
                DELETE FROM query_history WHERE id NOT IN (
                    SELECT id FROM query_history ORDER BY timestamp DESC LIMIT ?
                )
                """, bindings: [String(capacity)])
            return ok
        }
    }

    func entries() -> [String] {
        db.query(
            "SELECT query FROM query_history ORDER BY timestamp DESC LIMIT ?",
            bindings: [String(capacity)]
        ) { row in
            row.string(at: 0)
        }
    }

    func clearAll() {
        db.execute("DELETE FROM query_history")
    }

    // MARK: - Private

    private func createTable() {
        db.execute("""
            CREATE TABLE IF NOT EXISTS query_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                query TEXT NOT NULL UNIQUE,
                timestamp REAL NOT NULL
            )
            """)
    }
}
