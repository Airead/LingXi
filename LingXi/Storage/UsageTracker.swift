import Foundation
import OSLog
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class UsageTracker {
    private var db: OpaquePointer?
    private let prefixLength = 3
    private let queue = DispatchQueue(label: "com.lingxi.usagetracker")
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.airead.lingxi",
        category: "UsageTracker"
    )

    init(databasePath: String? = nil) {
        let path = databasePath ?? Self.defaultDatabasePath()
        queue.sync {
            openDatabase(at: path)
            createTableIfNeeded()
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public API

    func record(query: String, itemId: String) {
        queue.sync {
            let prefix = queryPrefix(query)
            let sql = "INSERT INTO usage (prefix, item_id, count) VALUES (?, ?, 1) ON CONFLICT(prefix, item_id) DO UPDATE SET count = count + 1"

            execute("BEGIN")
            let ok1 = execute(sql, bindings: [prefix, itemId])
            // Also record with empty prefix as global frequency, used for ranking when query is empty
            let ok2 = !prefix.isEmpty ? execute(sql, bindings: ["", itemId]) : true
            execute(ok1 && ok2 ? "COMMIT" : "ROLLBACK")
        }
    }

    func score(query: String, itemId: String) -> Int {
        queue.sync {
            fetchScores(query: query, itemIds: [itemId])[itemId] ?? 0
        }
    }

    func scores(query: String, itemIds: [String]) -> [String: Int] {
        guard !itemIds.isEmpty else { return [:] }
        return queue.sync {
            fetchScores(query: query, itemIds: itemIds)
        }
    }

    func clearAll() {
        queue.sync {
            _ = execute("DELETE FROM usage")
        }
    }

    // MARK: - Private

    /// Must be called on `queue`.
    private func fetchScores(query: String, itemIds: [String]) -> [String: Int] {
        let prefix = queryPrefix(query)
        let placeholders = itemIds.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT item_id, count FROM usage WHERE prefix = ? AND item_id IN (\(placeholders))"
        let bindings = [prefix] + itemIds

        var result: [String: Int] = [:]
        guard let stmt = prepareStatement(sql, bindings: bindings) else { return result }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 0) else { continue }
            let itemId = String(cString: cString)
            let count = Int(sqlite3_column_int(stmt, 1))
            result[itemId] = count
        }
        return result
    }

    private func queryPrefix(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        return String(trimmed.prefix(prefixLength))
    }

    private static func defaultDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LingXi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.db").path
    }

    private func openDatabase(at path: String) {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            Self.logger.warning("Failed to open database at \(path, privacy: .public), falling back to in-memory database")
            sqlite3_open(":memory:", &db)
            return
        }
    }

    private func createTableIfNeeded() {
        let sql = """
            CREATE TABLE IF NOT EXISTS usage (
                prefix TEXT NOT NULL,
                item_id TEXT NOT NULL,
                count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (prefix, item_id)
            )
            """
        execute(sql)
    }

    private func prepareStatement(_ sql: String, bindings: [String] = []) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }

        for (index, value) in bindings.enumerated() {
            _ = value.withCString { cString in
                sqlite3_bind_text(stmt, Int32(index + 1), cString, -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }

    @discardableResult
    private func execute(_ sql: String, bindings: [String] = []) -> Bool {
        guard let stmt = prepareStatement(sql, bindings: bindings) else { return false }
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }
}
