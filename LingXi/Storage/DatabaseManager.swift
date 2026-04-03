import Foundation
import OSLog
import SQLite3

/// Type-safe row accessor that encapsulates the raw SQLite statement pointer.
struct Row {
    fileprivate let stmt: OpaquePointer

    func string(at index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    func int(at index: Int32) -> Int {
        Int(sqlite3_column_int(stmt, index))
    }
}

/// Restricted handle passed to `transaction` blocks. Only exposes lock-free operations.
struct TransactionContext {
    fileprivate let db: DatabaseManager

    @discardableResult
    func execute(_ sql: String, bindings: [String] = []) -> Bool {
        db.executeWithoutLock(sql, bindings: bindings)
    }

    func query<T>(_ sql: String, bindings: [String] = [], map: (Row) -> T) -> [T] {
        db.queryWithoutLock(sql, bindings: bindings, map: map)
    }
}

final class DatabaseManager: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "io.github.airead.lingxi.database")
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.airead.lingxi",
        category: "DatabaseManager"
    )

    init(databasePath: String = ":memory:") {
        queue.sync {
            openDatabase(at: databasePath)
        }
    }

    deinit {
        let db = self.db
        queue.sync { _ = sqlite3_close(db) }
    }

    // MARK: - Public API

    @discardableResult
    func execute(_ sql: String, bindings: [String] = []) -> Bool {
        queue.sync {
            executeWithoutLock(sql, bindings: bindings)
        }
    }

    /// Run multiple statements in a single transaction.
    func transaction(_ block: (TransactionContext) -> Bool) -> Bool {
        queue.sync {
            executeWithoutLock("BEGIN")
            let success = block(TransactionContext(db: self))
            executeWithoutLock(success ? "COMMIT" : "ROLLBACK")
            return success
        }
    }

    func query<T>(_ sql: String, bindings: [String] = [], map: (Row) -> T) -> [T] {
        queue.sync {
            queryWithoutLock(sql, bindings: bindings, map: map)
        }
    }

    // MARK: - Lock-free (called on queue only)

    @discardableResult
    fileprivate func executeWithoutLock(_ sql: String, bindings: [String] = []) -> Bool {
        guard let stmt = prepareStatement(sql, bindings: bindings) else { return false }
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }

    fileprivate func queryWithoutLock<T>(_ sql: String, bindings: [String] = [], map: (Row) -> T) -> [T] {
        guard let stmt = prepareStatement(sql, bindings: bindings) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(map(Row(stmt: stmt)))
        }
        return results
    }

    // MARK: - Private

    private func openDatabase(at path: String) {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            Self.logger.warning("Failed to open database at \(path, privacy: .public), falling back to in-memory database")
            sqlite3_open(":memory:", &db)
            return
        }
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepareStatement(_ sql: String, bindings: [String]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }

        for (index, value) in bindings.enumerated() {
            _ = value.withCString { cString in
                sqlite3_bind_text(stmt, Int32(index + 1), cString, -1, Self.sqliteTransient)
            }
        }
        return stmt
    }

    static func defaultDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LingXi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.db").path
    }
}
