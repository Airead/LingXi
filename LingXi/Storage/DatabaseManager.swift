import Foundation
import OSLog
import SQLite3

/// Type-safe row accessor that encapsulates the raw SQLite statement pointer.
nonisolated struct Row {
    fileprivate let stmt: OpaquePointer

    nonisolated func string(at index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    nonisolated func int(at index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    nonisolated func double(at index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }
}

/// Type-safe SQL binding value.
enum DatabaseValue: Sendable {
    case text(String)
    case integer(Int)
    case real(Double)
    case null
}

actor DatabaseManager {
    private var db: OpaquePointer?
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.airead.lingxi",
        category: "DatabaseManager"
    )

    init(databasePath: String = ":memory:") async {
        openDatabase(at: databasePath)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public API

    @discardableResult
    func execute(_ sql: String, bindings: [DatabaseValue] = []) -> Bool {
        guard let stmt = prepareStatement(sql, bindings: bindings) else { return false }
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }

    /// Run multiple statements in a single transaction.
    func transaction(_ block: (isolated DatabaseManager) -> Bool) -> Bool {
        execute("BEGIN")
        let success = block(self)
        execute(success ? "COMMIT" : "ROLLBACK")
        return success
    }

    func query<T>(_ sql: String, bindings: [DatabaseValue] = [], map: (Row) -> T) -> [T] {
        guard let stmt = prepareStatement(sql, bindings: bindings) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(map(Row(stmt: stmt)))
        }
        return results
    }

    var lastInsertRowId: Int {
        Int(sqlite3_last_insert_rowid(db))
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

    private func prepareStatement(_ sql: String, bindings: [DatabaseValue]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }

        for (index, value) in bindings.enumerated() {
            let pos = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let str):
                result = str.withCString { cString in
                    sqlite3_bind_text(stmt, pos, cString, -1, Self.sqliteTransient)
                }
            case .integer(let num):
                result = sqlite3_bind_int64(stmt, pos, Int64(num))
            case .real(let dbl):
                result = sqlite3_bind_double(stmt, pos, dbl)
            case .null:
                result = sqlite3_bind_null(stmt, pos)
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return nil
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
