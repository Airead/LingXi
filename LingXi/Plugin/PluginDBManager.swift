import CryptoKit
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
    case blob(Data)
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
    case snapshotFailed(String)

    var message: String {
        switch self {
        case .invalidName(let m): "invalid db name: \(m)"
        case .openFailed(let m): "open failed: \(m)"
        case .handleNotFound: "db handle not found or already closed"
        case .prepareFailed(let m): "prepare failed: \(m)"
        case .bindFailed(let m): "bind failed: \(m)"
        case .stepFailed(let m): "step failed: \(m)"
        case .unsupportedParamType(let i): "unsupported param type at index \(i)"
        case .snapshotFailed(let m): "snapshot failed: \(m)"
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
            if rc == SQLITE_CANTOPEN {
                msg += " — \(Self.cantOpenHint(path: canonicalPath))"
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

    // MARK: - Snapshot

    /// Copy an external SQLite file into this plugin's snapshots cache using the
    /// SQLite Backup API so concurrent writers on the source do not corrupt the
    /// copy. Returns the canonical path of the snapshot file. Overwrites any
    /// previous snapshot for the same source path.
    ///
    /// Callers must have already path-validated `canonicalSourcePath` against
    /// `db_external_paths`. The destination path is always inside the plugin's
    /// own cache subtree, so it does not need whitelist authorization.
    func snapshotExternal(pluginId: String, canonicalSourcePath: String) -> Result<String, PluginDBError> {
        guard !pluginId.isEmpty else {
            return .failure(.invalidName("empty pluginId"))
        }
        guard FileManager.default.fileExists(atPath: canonicalSourcePath) else {
            return .failure(.snapshotFailed("source does not exist: \(canonicalSourcePath)"))
        }

        let snapshotsURL = snapshotsDirectoryURL(pluginId: pluginId)
        do {
            try FileManager.default.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
        } catch {
            return .failure(.snapshotFailed("cannot create snapshots dir: \(error.localizedDescription)"))
        }

        let hash = Self.shortHash(canonicalSourcePath)
        let destURL = snapshotsURL.appendingPathComponent("\(hash).sqlite")
        let destPath = destURL.path

        // Remove any previous snapshot (and stale WAL sidecars) before rewriting.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: destPath + suffix)
        }

        let escaped = canonicalSourcePath
            .replacingOccurrences(of: "?", with: "%3f")
            .replacingOccurrences(of: "#", with: "%23")
        let srcURI = "file:\(escaped)?mode=ro&immutable=1"

        var srcDB: OpaquePointer?
        let srcRC = sqlite3_open_v2(srcURI, &srcDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if srcRC != SQLITE_OK {
            var msg: String
            if let srcDB {
                msg = String(cString: sqlite3_errmsg(srcDB))
                sqlite3_close_v2(srcDB)
            } else {
                msg = "sqlite3_open_v2 rc=\(srcRC)"
            }
            if srcRC == SQLITE_CANTOPEN {
                msg += " — \(Self.cantOpenHint(path: canonicalSourcePath))"
            }
            return .failure(.snapshotFailed("open source: \(msg)"))
        }
        guard let srcDB else {
            return .failure(.snapshotFailed("null source handle"))
        }
        defer { sqlite3_close_v2(srcDB) }

        var destDB: OpaquePointer?
        let destRC = sqlite3_open_v2(destPath, &destDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        if destRC != SQLITE_OK {
            let msg: String
            if let destDB {
                msg = String(cString: sqlite3_errmsg(destDB))
                sqlite3_close_v2(destDB)
            } else {
                msg = "sqlite3_open_v2 rc=\(destRC)"
            }
            try? FileManager.default.removeItem(atPath: destPath)
            return .failure(.snapshotFailed("open dest: \(msg)"))
        }
        guard let destDB else {
            return .failure(.snapshotFailed("null dest handle"))
        }
        defer { sqlite3_close_v2(destDB) }

        guard let backup = sqlite3_backup_init(destDB, "main", srcDB, "main") else {
            let msg = String(cString: sqlite3_errmsg(destDB))
            try? FileManager.default.removeItem(atPath: destPath)
            return .failure(.snapshotFailed("backup_init: \(msg)"))
        }
        let stepRC = sqlite3_backup_step(backup, -1)
        _ = sqlite3_backup_finish(backup)
        if stepRC != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(destDB))
            try? FileManager.default.removeItem(atPath: destPath)
            return .failure(.snapshotFailed("backup_step rc=\(stepRC): \(msg)"))
        }

        return .success(destPath)
    }

    /// If `path` (after ~-expansion and symlink resolution) lies inside this
    /// plugin's snapshots subdirectory, returns the canonical path. Otherwise
    /// returns nil. Used by `openExternal` to auto-allow previously produced
    /// snapshot files without requiring them to be listed in `db_external_paths`.
    func resolveSnapshotPath(pluginId: String, path: String) -> String? {
        guard !pluginId.isEmpty else { return nil }
        let snapshotsDir = canonicalize(snapshotsDirectoryURL(pluginId: pluginId).path)
        let expanded = Self.expandTilde(path)
        let canonical = canonicalize(expanded)
        if canonical == snapshotsDir { return canonical }
        if canonical.hasPrefix(snapshotsDir + "/") { return canonical }
        return nil
    }

    private func snapshotsDirectoryURL(pluginId: String) -> URL {
        baseDirectory
            .appendingPathComponent(pluginId, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    private func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        }
        return path
    }

    private static func shortHash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
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

    // MARK: - Transactions

    /// Begin a transaction. Fails if the connection is already inside one.
    /// Uses `sqlite3_get_autocommit` as the single source of truth so that
    /// plugin code running raw `BEGIN` via `exec` stays consistent.
    func beginTransaction(handleId: Int) -> Result<Void, PluginDBError> {
        guard let conn = connections[handleId] else {
            return .failure(.handleNotFound)
        }
        if sqlite3_get_autocommit(conn.db) == 0 {
            return .failure(.stepFailed("already in transaction"))
        }
        return stepBare(db: conn.db, sql: "BEGIN")
    }

    func commitTransaction(handleId: Int) -> Result<Void, PluginDBError> {
        guard let conn = connections[handleId] else {
            return .failure(.handleNotFound)
        }
        return stepBare(db: conn.db, sql: "COMMIT")
    }

    /// Rollback is best-effort — the caller typically wants cleanup on a
    /// broken-transaction path and cares less about the specific failure mode.
    func rollbackTransaction(handleId: Int) {
        guard let conn = connections[handleId] else { return }
        _ = stepBare(db: conn.db, sql: "ROLLBACK")
    }

    private func stepBare(db: OpaquePointer, sql: String) -> Result<Void, PluginDBError> {
        var stmt: OpaquePointer?
        let prc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if prc != SQLITE_OK {
            return .failure(.prepareFailed(String(cString: sqlite3_errmsg(db))))
        }
        defer { sqlite3_finalize(stmt) }
        let src = sqlite3_step(stmt)
        if src != SQLITE_DONE && src != SQLITE_ROW {
            return .failure(.stepFailed(String(cString: sqlite3_errmsg(db))))
        }
        return .success(())
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
            case .blob(let d):
                rc = d.withUnsafeBytes { raw in
                    if let base = raw.baseAddress, d.count > 0 {
                        return sqlite3_bind_blob(stmt, pos, base, Int32(d.count), sqliteTransient)
                    }
                    return sqlite3_bind_zeroblob(stmt, pos, 0)
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
            let count = Int(sqlite3_column_bytes(stmt, index))
            if count == 0 { return .blob(Data()) }
            if let ptr = sqlite3_column_blob(stmt, index) {
                return .blob(Data(bytes: ptr, count: count))
            }
            return .blob(Data())
        default:
            return .null
        }
    }

    /// Diagnose why SQLite returned `SQLITE_CANTOPEN` by probing the path with
    /// a POSIX `open()`. Distinguishes TCC / filesystem permissions from
    /// missing files and other failures so plugins get actionable error text.
    private static func cantOpenHint(path: String) -> String {
        if !FileManager.default.fileExists(atPath: path) {
            return "file not found"
        }
        let fd = Darwin.open(path, O_RDONLY)
        if fd < 0 {
            let e = errno
            switch e {
            case EACCES, EPERM:
                return "permission denied (may need Full Disk Access)"
            default:
                return "open errno=\(e)"
            }
        }
        Darwin.close(fd)
        return "file readable but SQLite could not open (WAL/lock or header issue?)"
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
private nonisolated final class Connection: @unchecked Sendable {
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

    nonisolated func syncBeginTransaction(handleId: Int) -> Result<Void, PluginDBError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, PluginDBError> = .failure(.handleNotFound)
        Task {
            result = await beginTransaction(handleId: handleId)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    nonisolated func syncCommitTransaction(handleId: Int) -> Result<Void, PluginDBError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, PluginDBError> = .failure(.handleNotFound)
        Task {
            result = await commitTransaction(handleId: handleId)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    nonisolated func syncRollbackTransaction(handleId: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await rollbackTransaction(handleId: handleId)
            semaphore.signal()
        }
        semaphore.wait()
    }

    nonisolated func syncSnapshotExternal(pluginId: String, canonicalSourcePath: String) -> Result<String, PluginDBError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, PluginDBError> = .failure(.snapshotFailed("unreached"))
        Task {
            result = await snapshotExternal(pluginId: pluginId, canonicalSourcePath: canonicalSourcePath)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    nonisolated func syncResolveSnapshotPath(pluginId: String, path: String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        Task {
            result = await resolveSnapshotPath(pluginId: pluginId, path: path)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
