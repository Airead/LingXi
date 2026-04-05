import Foundation

nonisolated final class UsageTracker: Sendable {
    private let db: DatabaseManager
    private let prefixLength = 3
    private let setupTask: Task<Void, Never>

    init(database: DatabaseManager) {
        self.db = database
        self.setupTask = Task {
            await database.execute("""
                CREATE TABLE IF NOT EXISTS usage (
                    prefix TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    count INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (prefix, item_id)
                )
                """)
        }
    }

    // MARK: - Public API

    func record(query: String, itemId: String) async {
        await setupTask.value
        let prefix = queryPrefix(query)
        let sql = "INSERT INTO usage (prefix, item_id, count) VALUES (?, ?, 1) ON CONFLICT(prefix, item_id) DO UPDATE SET count = count + 1"

        _ = await db.transaction { tx in
            let ok1 = tx.execute(sql, bindings: [.text(prefix), .text(itemId)])
            let ok2 = !prefix.isEmpty ? tx.execute(sql, bindings: [.text(""), .text(itemId)]) : true
            return ok1 && ok2
        }
    }

    func score(query: String, itemId: String) async -> Int {
        await scores(query: query, itemIds: [itemId])[itemId] ?? 0
    }

    func scores(query: String, itemIds: [String]) async -> [String: Int] {
        await setupTask.value
        guard !itemIds.isEmpty else { return [:] }

        let prefix = queryPrefix(query)
        let placeholders = itemIds.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT item_id, count FROM usage WHERE prefix = ? AND item_id IN (\(placeholders))"
        let bindings: [DatabaseValue] = [.text(prefix)] + itemIds.map { .text($0) }

        let rows = await db.query(sql, bindings: bindings) { row -> (String, Int) in
            (row.string(at: 0), row.int(at: 1))
        }

        return Dictionary(uniqueKeysWithValues: rows)
    }

    func clearAll() async {
        await setupTask.value
        await db.execute("DELETE FROM usage")
    }

    // MARK: - Private

    private func queryPrefix(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(trimmed.prefix(prefixLength))
    }
}
