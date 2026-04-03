import Foundation

final class UsageTracker: Sendable {
    private let db: DatabaseManager
    private let prefixLength = 3

    init(database: DatabaseManager = DatabaseManager()) {
        self.db = database
        createTable()
    }

    // MARK: - Public API

    func record(query: String, itemId: String) {
        let prefix = queryPrefix(query)
        let sql = "INSERT INTO usage (prefix, item_id, count) VALUES (?, ?, 1) ON CONFLICT(prefix, item_id) DO UPDATE SET count = count + 1"

        _ = db.transaction { tx in
            let ok1 = tx.execute(sql, bindings: [prefix, itemId])
            let ok2 = !prefix.isEmpty ? tx.execute(sql, bindings: ["", itemId]) : true
            return ok1 && ok2
        }
    }

    func score(query: String, itemId: String) -> Int {
        scores(query: query, itemIds: [itemId])[itemId] ?? 0
    }

    func scores(query: String, itemIds: [String]) -> [String: Int] {
        guard !itemIds.isEmpty else { return [:] }

        let prefix = queryPrefix(query)
        let placeholders = itemIds.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT item_id, count FROM usage WHERE prefix = ? AND item_id IN (\(placeholders))"
        let bindings = [prefix] + itemIds

        let rows = db.query(sql, bindings: bindings) { row -> (String, Int) in
            (row.string(at: 0), row.int(at: 1))
        }

        return Dictionary(uniqueKeysWithValues: rows)
    }

    func clearAll() {
        db.execute("DELETE FROM usage")
    }

    // MARK: - Private

    private func queryPrefix(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(trimmed.prefix(prefixLength))
    }

    private func createTable() {
        db.execute("""
            CREATE TABLE IF NOT EXISTS usage (
                prefix TEXT NOT NULL,
                item_id TEXT NOT NULL,
                count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (prefix, item_id)
            )
            """)
    }
}
