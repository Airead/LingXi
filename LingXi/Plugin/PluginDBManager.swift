import Foundation
import SQLite3

/// Type-safe SQL binding value for plugin DB API.
/// Mirrors `DatabaseValue` in the host's `DatabaseManager` but is owned by this
/// module so the plugin surface can evolve independently.
enum PluginDBValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
}

/// Row returned from a plugin query: column name -> value.
typealias PluginDBRow = [(String, PluginDBValue)]

/// Error returned from plugin DB operations.
enum PluginDBError: Error, Equatable {
    case invalidName(String)
    case openFailed(String)
    case handleNotFound
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)
    case unsupportedParamType(Int)

    var message: String {
        switch self {
        case .invalidName(let m): "invalid db name: \(m)"
        case .openFailed(let m): "open failed: \(m)"
        case .handleNotFound: "db handle not found or already closed"
        case .prepareFailed(let m): "prepare failed: \(m)"
        case .bindFailed(let m): "bind failed: \(m)"
        case .stepFailed(let m): "step failed: \(m)"
        case .unsupportedParamType(let i): "unsupported param type at index \(i)"
        }
    }
}

/// Actor-isolated manager for plugin-owned SQLite databases.
///
/// Each plugin's databases live at `<baseDirectory>/<plugin-id>/<name>.sqlite`.
/// Connections are keyed by a monotonic `handleId` so Lua userdata can store
/// a plain integer instead of a raw pointer.
actor PluginDBManager {
    static let shared = PluginDBManager()

    private var baseDirectory: URL
    private var nextHandleId: Int = 1
    private var connections: [Int: Connection] = [:]
    private var pluginHandles: [String: Set<Int>] = [:]

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            self.baseDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/LingXi/plugin-db", isDirectory: true)
        }
    }

    // MARK: - Open / close

    func openOwned(pluginId: String, name: String) -> Result<Int, PluginDBError> {
        guard Self.isValidName(name) else {
            return .failure(.invalidName(name))
        }
        guard !pluginId.isEmpty else {
            return .failure(.invalidName("empty pluginId"))
        }

        let pluginDir = baseDirectory.appendingPathComponent(pluginId, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.openFailed("cannot create db dir: \(error.localizedDescription)"))
        }

        let dbPath = pluginDir.appendingPathComponent("\(name).sqlite").path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let rc = sqlite3_open_v2(dbPath, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg: String
            if let handle {
                msg = String(cString: sqlite3_errmsg(handle))
                sqlite3_close_v2(handle)
            } else {
                msg = "sqlite3_open_v2 rc=\(rc)"
            }
            return .failure(.openFailed(msg))
        }
        guard let handle else {
            return .failure(.openFailed("null handle"))
        }

        Self.applyDefaultPragmas(handle)

        let id = nextHandleId
        nextHandleId += 1
        connections[id] = Connection(db: handle, isReadOnly: false)
        pluginHandles[pluginId, default: []].insert(id)
        return .success(id)
    }

    /// Open an external SQLite file read-only. `canonicalPath` must already
    /// have been path-validated (symlinks resolved, whitelist enforced) by the
    /// caller. The DB is opened with `mode=ro&immutable=1` so SQLite will not
    /// try to create `-shm`/`-wal` sidecar files.
    func openExternal(pluginId: String, canonicalPath: String) -> Result<Int, PluginDBError> {
        guard !pluginId.isEmpty else {
            return .failure(.invalidName("empty pluginId"))
        }
        guard FileManager.default.fileExists(atPath: canonicalPath) else {
            return .failure(.openFailed("file does not exist: \(canonicalPath)"))
        }

        // SQLite URI form: escape '?' and '#' in the path.
        let escaped = canonicalPath
            .replacingOccurrences(of: "?", with: "%3f")
            .replacingOccurrences(of: "#", with: "%23")
        let uri = "file:\(escaped)?mode=ro&immutable=1"

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2(uri, &handle, flags, nil)
        if rc != SQLITE_OK {
            var msg: String
            if let handle {
                msg = String(cString: sqlite3_errmsg(handle))
                sqlite3_close_v2(handle)
            } else {
                msg = "sqlite3_open_v2 rc=\(rc)"
            }
            // Hint at TCC: readable file that SQLite cannot open often means
            // the app is missing Full Disk Access for that location.
            if rc == SQLITE_CANTOPEN {
                msg += " (may need Full Disk Access)"
            }
            return .failure(.openFailed(msg))
        }
        guard let handle else {
            return .failure(.openFailed("null handle"))
        }

        // Read-only connection: busy_timeout is still useful in case another
        // writer holds the lock briefly. journal_mode/foreign_keys pragmas are
        // no-ops on a readonly connection, so skip them.
        sqlite3_exec(handle, "PRAGMA busy_timeout=3000;", nil, nil, nil)

        let id = nextHandleId
        nextHandleId += 1
        connections[id] = Connection(db: handle, isReadOnly: true)
        pluginHandles[pluginId, default: []].insert(id)
        return .success(id)
    }

    func close(pluginId: String, handleId: Int) {
        guard let conn = connections.removeValue(forKey: handleId) else { return }
        pluginHandles[pluginId]?.remove(handleId)
        if pluginHandles[pluginId]?.isEmpty == true {
            pluginHandles.removeValue(forKey: pluginId)
        }
        sqlite3_close_v2(conn.db)
    }

    func closeAll(pluginId: String) {
        guard let ids = pluginHandles.removeValue(forKey: pluginId) else { return }
        for id in ids {
            if let conn = connections.removeValue(forKey: id) {
                sqlite3_close_v2(conn.db)
            }
        }
    }

    /// Test-only: close every connection and redirect the base directory.
    /// Used by unit tests to isolate state from the shared singleton.
    func resetForTesting(baseDirectory: URL) {
        for (_, conn) in connections {
            sqlite3_close_v2(conn.db)
        }
        connections.removeAll()
        pluginHandles.removeAll()
        nextHandleId = 1
        self.baseDirectory = baseDirectory
    }

    // MARK: - Execute / query

    /// Execute a statement. Returns the number of rows changed.
    func exec(handleId: Int, sql: String, params: [PluginDBValue]) -> Result<Int, PluginDBError> {
        guard let conn = connections[handleId] else {
            return .failure(.handleNotFound)
        }

        var stmt: OpaquePointer?
        let prc = sqlite3_prepare_v2(conn.db, sql, -1, &stmt, nil)
        if prc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(conn.db))
            return .failure(.prepareFailed(msg))
        }
        defer { sqlite3_finalize(stmt) }

        if let bindErr = Self.bind(stmt: stmt, params: params, db: conn.db) {
            return .failure(bindErr)
        }

        let src = sqlite3_step(stmt)
        if src != SQLITE_DONE && src != SQLITE_ROW {
            let msg = String(cString: sqlite3_errmsg(conn.db))
            return .failure(.stepFailed(msg))
        }
        return .success(Int(sqlite3_changes(conn.db)))
    }

    /// Query rows. Returns ordered column/value pairs per row so callers can
    /// preserve column order when pushing into Lua.
    func query(handleId: Int, sql: String, params: [PluginDBValue]) -> Result<[PluginDBRow], PluginDBError> {
        guard let conn = connections[handleId] else {
            return .failure(.handleNotFound)
        }

        var stmt: OpaquePointer?
        let prc = sqlite3_prepare_v2(conn.db, sql, -1, &stmt, nil)
        if prc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(conn.db))
            return .failure(.prepareFailed(msg))
        }
        defer { sqlite3_finalize(stmt) }

        if let bindErr = Self.bind(stmt: stmt, params: params, db: conn.db) {
            return .failure(bindErr)
        }

        let columnCount = sqlite3_column_count(stmt)
        var columnNames: [String] = []
        columnNames.reserveCapacity(Int(columnCount))
        for i in 0..<columnCount {
            if let c = sqlite3_column_name(stmt, i) {
                columnNames.append(String(cString: c))
            } else {
                columnNames.append("")
            }
        }

        var rows: [PluginDBRow] = []
        while true {
            let src = sqlite3_step(stmt)
            if src == SQLITE_DONE { break }
            if src != SQLITE_ROW {
                let msg = String(cString: sqlite3_errmsg(conn.db))
                return .failure(.stepFailed(msg))
            }
            var row: PluginDBRow = []
            row.reserveCapacity(Int(columnCount))
            for i in 0..<columnCount {
                row.append((columnNames[Int(i)], Self.columnValue(stmt: stmt, index: i)))
            }
            rows.append(row)
        }
        return .success(rows)
    }

    /// Query first row. Returns nil when no rows matched.
    func queryOne(handleId: Int, sql: String, params: [PluginDBValue]) -> Result<PluginDBRow?, PluginDBError> {
        switch query(handleId: handleId, sql: sql, params: params) {
        case .failure(let err): return .failure(err)
        case .success(let rows): return .success(rows.first)
        }
    }

    // MARK: - Validation / helpers

    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name == "." || name == ".." { return false }
        for ch in name.unicodeScalars {
            if ch == "/" || ch == "\\" || ch.value == 0 { return false }
        }
        return true
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bind(stmt: OpaquePointer?, params: [PluginDBValue], db: OpaquePointer) -> PluginDBError? {
        for (idx, value) in params.enumerated() {
            let pos = Int32(idx + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, pos)
            case .integer(let i):
                rc = sqlite3_bind_int64(stmt, pos, i)
            case .real(let d):
                rc = sqlite3_bind_double(stmt, pos, d)
            case .text(let s):
                rc = s.withCString { c in
                    sqlite3_bind_text(stmt, pos, c, -1, sqliteTransient)
                }
            }
            if rc != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                return .bindFailed("\(msg) (param \(pos))")
            }
        }
        return nil
    }

    private static func columnValue(stmt: OpaquePointer?, index: Int32) -> PluginDBValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            if let c = sqlite3_column_text(stmt, index) {
                return .text(String(cString: c))
            }
            return .null
        case SQLITE_NULL:
            return .null
        case SQLITE_BLOB:
            // BLOB support is deferred to a later phase (see plan P5).
            // For now, return text representation length so callers see non-null.
            let bytes = sqlite3_column_bytes(stmt, index)
            return .text("<blob:\(bytes) bytes>")
        default:
            return .null
        }
    }

    private static func applyDefaultPragmas(_ db: OpaquePointer) {
        let pragmas = [
            "PRAGMA journal_mode=WAL;",
            "PRAGMA foreign_keys=ON;",
            "PRAGMA busy_timeout=5000;",
        ]
        for sql in pragmas {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }
}

/// Internal connection wrapper. The `db` pointer is only touched while holding
/// actor isolation on `PluginDBManager`, which serializes access.
private final class Connection: @unchecked Sendable {
    let db: OpaquePointer
    let isReadOnly: Bool

    init(db: OpaquePointer, isReadOnly: Bool) {
        self.db = db
        self.isReadOnly = isReadOnly
    }
}

// MARK: - Synchronous wrappers for Lua C callbacks

extension PluginDBManager {
    nonisolated func syncOpenOwned(pluginId: String, name: String) -> Result<Int, PluginDBError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Int, PluginDBError> = .failure(.handleNotFound)
        Task {
            result = await openOwned(pluginId: pluginId, name: name)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    nonisolated func syncOpenExternal(pluginId: String, canonicalPath: String) -> Result<Int, PluginDBError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Int, PluginDBError> = .failure(.handleNotFound)
        Task {
            result = await openExternal(pluginId: pluginId, canonicalPath: canonicalPath)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    nonisolated func syncClose(pluginId: String, handleId: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await close(pluginId: pluginId, handleId: handleId)
            semaphore.signal()
        }
        semaphore.wait()
    }

    nonisolated func syncCloseAll(pluginId: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await closeAll(pluginId: pluginId)
            semaphore.signal()
        }
        semaphore.wait()
    }

    nonisolated func syncExec(handleId: Int, sql: String, params: [PluginDBValue]) -> Result<Int, PluginDBError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Int, PluginDBError> = .failure(.handleNotFound)
        Task {
            result = await exec(handleId: handleId, sql: sql, params: params)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    nonisolated func syncQuery(handleId: Int, sql: String, params: [PluginDBValue]) -> Result<[PluginDBRow], PluginDBError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[PluginDBRow], PluginDBError> = .failure(.handleNotFound)
        Task {
            result = await query(handleId: handleId, sql: sql, params: params)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    nonisolated func syncQueryOne(handleId: Int, sql: String, params: [PluginDBValue]) -> Result<PluginDBRow?, PluginDBError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<PluginDBRow?, PluginDBError> = .failure(.handleNotFound)
        Task {
            result = await queryOne(handleId: handleId, sql: sql, params: params)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
