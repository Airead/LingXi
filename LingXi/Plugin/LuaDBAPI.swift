import CLua
import Foundation

/// Registers `lingxi.db` APIs for plugin-owned SQLite databases.
///
/// Lua surface:
///   local db = lingxi.db.open("name")             -- owned DB under ~/.cache/LingXi/plugin-db/<plugin-id>/
///   db:exec(sql, params)                          -> changes | nil, err
///   db:query(sql, params)                         -> rows[]  | nil, err
///   db:queryOne(sql, params)                      -> row|nil | nil, err
///   db:close()                                    -> true
nonisolated enum LuaDBAPI {
    private static let ownedMetatableName = "lingxi.db.owned"
    private static let externalMetatableName = "lingxi.db.external"

    /// Per-plugin whitelist for `lingxi.db.openExternal`. Populated by
    /// `register(state:pluginId:externalPaths:)` and consulted by the C
    /// callback to validate external DB paths.
    private static var externalPermissions: [String: [String]] = [:]

    // MARK: - Registration

    static func register(state: LuaState, pluginId: String = "", externalPaths: [String] = []) {
        ensureMetatables(L: state.raw)

        if !pluginId.isEmpty {
            externalPermissions[pluginId] = externalPaths
        }

        state.createTable(nrec: 4)
        state.pushFunction(dbOpen)
        state.setField("open", at: -2)
        state.pushFunction(dbOpenExternal)
        state.setField("openExternal", at: -2)
        state.pushFunction(dbSnapshot)
        state.setField("snapshot", at: -2)
        state.pushFunction(dbBlob)
        state.setField("blob", at: -2)
        state.setField("db", at: -2)
    }

    static func registerDisabled(state: LuaState) {
        state.createTable(nrec: 4)
        state.pushFunction(disabledOpen)
        state.setField("open", at: -2)
        state.pushFunction(disabledOpen)
        state.setField("openExternal", at: -2)
        state.pushFunction(disabledSnapshot)
        state.setField("snapshot", at: -2)
        // `blob` is a pure constructor — safe to register even without db
        // permission. Plugins that never open a db won't have anywhere to
        // send the wrapper, but calling it is harmless.
        state.pushFunction(dbBlob)
        state.setField("blob", at: -2)
        state.setField("db", at: -2)
    }

    // MARK: - Metatable setup

    private static func ensureMetatables(L: OpaquePointer) {
        // Owned DB metatable: exec + query + queryOne + transaction + close.
        if luaL_newmetatable(L, ownedMetatableName) != 0 {
            lua_createtable(L, 0, 5)
            lua_swift_pushcfunction(L, dbExec)
            lua_setfield(L, -2, "exec")
            lua_swift_pushcfunction(L, dbQuery)
            lua_setfield(L, -2, "query")
            lua_swift_pushcfunction(L, dbQueryOne)
            lua_setfield(L, -2, "queryOne")
            lua_swift_pushcfunction(L, dbTransaction)
            lua_setfield(L, -2, "transaction")
            lua_swift_pushcfunction(L, dbClose)
            lua_setfield(L, -2, "close")
            lua_setfield(L, -2, "__index")

            lua_swift_pushcfunction(L, dbGc)
            lua_setfield(L, -2, "__gc")

            lua_pushstring(L, "lingxi.db")
            lua_setfield(L, -2, "__metatable")
        }
        lua_swift_pop(L, 1)

        // External DB metatable: intentionally omits `exec` (read-only only).
        // Trying to call exec on an external handle raises "attempt to call
        // a nil value" at the Lua level.
        if luaL_newmetatable(L, externalMetatableName) != 0 {
            lua_createtable(L, 0, 3)
            lua_swift_pushcfunction(L, dbQuery)
            lua_setfield(L, -2, "query")
            lua_swift_pushcfunction(L, dbQueryOne)
            lua_setfield(L, -2, "queryOne")
            lua_swift_pushcfunction(L, dbClose)
            lua_setfield(L, -2, "close")
            lua_setfield(L, -2, "__index")

            lua_swift_pushcfunction(L, dbGc)
            lua_setfield(L, -2, "__gc")

            lua_pushstring(L, "lingxi.db.external")
            lua_setfield(L, -2, "__metatable")
        }
        lua_swift_pop(L, 1)
    }

    // MARK: - Helpers

    /// Retrieve the plugin ID from `lingxi._pluginId`.
    private static func pluginId(from L: OpaquePointer) -> String {
        lua_getglobal(L, "lingxi")
        guard lua_type(L, -1) == lua_swift_type_table() else {
            lua_swift_pop(L, 1)
            return ""
        }
        lua_getfield(L, -1, "_pluginId")
        let pid: String
        if let cstr = lua_swift_tostring(L, -1) {
            pid = String(cString: cstr)
        } else {
            pid = ""
        }
        lua_swift_pop(L, 2)
        return pid
    }

    /// Read the handleId from a userdata matching any of the provided metatables.
    /// Returns 0 if the type doesn't match or the handle has been closed.
    /// Uses `luaL_testudata` (non-raising) so callers can accept multiple types.
    private static func handleId(L: OpaquePointer, at index: Int32, metatables: [String]) -> Int {
        for name in metatables {
            if let ud = luaL_testudata(L, index, name) {
                return ud.assumingMemoryBound(to: Int.self).pointee
            }
        }
        return 0
    }

    /// Overwrite the handleId (used to invalidate on close) across either metatable.
    private static func setHandleId(L: OpaquePointer, at index: Int32, value: Int, metatables: [String]) {
        for name in metatables {
            if let ud = luaL_testudata(L, index, name) {
                ud.assumingMemoryBound(to: Int.self).pointee = value
                return
            }
        }
    }

    private static let anyDBMetatables = [ownedMetatableName, externalMetatableName]

    /// Convert a Lua table (array) at `paramsIndex` to `[PluginDBValue]`.
    /// If no table is present (nil / absent), returns empty array.
    /// Convert a Lua value at `paramsIndex` (expected to be a table or nil) into
    /// a `[PluginDBValue]` array. Returns `(nil, errorMessage)` on failure.
    private static func readParams(L: OpaquePointer, paramsIndex: Int32) -> (params: [PluginDBValue]?, error: String?) {
        let absIdx = lua_absindex(L, paramsIndex)
        let t = lua_type(L, absIdx)
        if t == lua_swift_type_nil() || t < 0 {
            return ([], nil)
        }
        if t != lua_swift_type_table() {
            return (nil, "params must be a table or nil")
        }

        var params: [PluginDBValue] = []
        let len = lua_rawlen(L, absIdx)
        if len == 0 { return ([], nil) }
        for i: lua_Unsigned in 1...len {
            lua_rawgeti(L, absIdx, lua_Integer(i))
            let vt = lua_type(L, -1)
            switch vt {
            case lua_swift_type_nil():
                params.append(.null)
            case lua_swift_type_number():
                if lua_isinteger(L, -1) != 0 {
                    params.append(.integer(Int64(lua_swift_tointeger(L, -1))))
                } else {
                    params.append(.real(lua_swift_tonumber(L, -1)))
                }
            case lua_swift_type_string():
                params.append(.text(readLuaString(L: L, at: -1)))
            case lua_swift_type_boolean():
                params.append(.integer(lua_toboolean(L, -1) != 0 ? 1 : 0))
            case lua_swift_type_table():
                // Only recognized table shape is the BLOB marker produced by
                // `lingxi.db.blob(str)`: { __blob = true, data = <string> }.
                if let blob = readBlobMarker(L: L, at: -1) {
                    params.append(.blob(blob))
                } else {
                    lua_swift_pop(L, 1)
                    return (nil, "unsupported table at param \(i) (use lingxi.db.blob for binary)")
                }
            default:
                lua_swift_pop(L, 1)
                return (nil, "unsupported param type at index \(i)")
            }
            lua_swift_pop(L, 1)
        }
        return (params, nil)
    }

    /// Read a Lua string at `index` as `String` — safe for binary bytes, uses
    /// `lua_rawlen` so embedded NULs survive round-trips through Swift.
    private static func readLuaString(L: OpaquePointer, at index: Int32) -> String {
        guard let cstr = lua_swift_tostring(L, index) else { return "" }
        let len = Int(lua_rawlen(L, index))
        let data = Data(bytes: cstr, count: len)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Read raw bytes from a Lua string at `index` (binary-safe).
    private static func readLuaBytes(L: OpaquePointer, at index: Int32) -> Data {
        guard let cstr = lua_swift_tostring(L, index) else { return Data() }
        let len = Int(lua_rawlen(L, index))
        return Data(bytes: cstr, count: len)
    }

    /// If the table at `index` is `{ __blob = true, data = <string> }`,
    /// return the raw bytes. Otherwise nil.
    private static func readBlobMarker(L: OpaquePointer, at index: Int32) -> Data? {
        let absIdx = lua_absindex(L, index)
        lua_getfield(L, absIdx, "__blob")
        let isBlob = lua_toboolean(L, -1) != 0
        lua_swift_pop(L, 1)
        guard isBlob else { return nil }
        lua_getfield(L, absIdx, "data")
        defer { lua_swift_pop(L, 1) }
        guard lua_type(L, -1) == lua_swift_type_string() else { return nil }
        return readLuaBytes(L: L, at: -1)
    }

    /// Push a PluginDBValue onto the Lua stack. BLOB columns are pushed as
    /// raw Lua strings (Lua strings are byte-safe) so plugins can treat them
    /// directly with string ops like `#b` for length.
    private static func pushValue(_ L: OpaquePointer, _ v: PluginDBValue) {
        switch v {
        case .null:
            lua_pushnil(L)
        case .integer(let i):
            lua_pushinteger(L, lua_Integer(i))
        case .real(let d):
            lua_pushnumber(L, d)
        case .text(let s):
            lua_pushstring(L, s)
        case .blob(let d):
            d.withUnsafeBytes { raw in
                if let base = raw.baseAddress, d.count > 0 {
                    _ = lua_pushlstring(L, base.assumingMemoryBound(to: CChar.self), d.count)
                } else {
                    _ = lua_pushlstring(L, "", 0)
                }
            }
        }
    }

    /// Push a row as a Lua table (string keys).
    private static func pushRow(_ L: OpaquePointer, _ row: PluginDBRow) {
        lua_createtable(L, 0, Int32(row.count))
        for (col, val) in row {
            pushValue(L, val)
            lua_setfield(L, -2, col)
        }
    }

    // MARK: - C Functions: open / stubs

    /// `lingxi.db.open(name) -> userdata | nil, err`
    private static let dbOpen: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        guard lua_type(L, 1) == lua_swift_type_string(),
              let cstr = lua_swift_tostring(L, 1) else {
            lua_pushnil(L)
            lua_pushstring(L, "name must be a string")
            return 2
        }
        let name = String(cString: cstr)
        let pid = pluginId(from: L)

        switch PluginDBManager.shared.syncOpenOwned(pluginId: pid, name: name) {
        case .failure(let err):
            DebugLog.log("[LuaDB] \(pid): open(\(name)) failed: \(err.message)")
            lua_pushnil(L)
            lua_pushstring(L, err.message)
            return 2
        case .success(let handleId):
            let ud = lua_newuserdatauv(L, MemoryLayout<Int>.size, 0)
            ud?.assumingMemoryBound(to: Int.self).pointee = handleId
            luaL_setmetatable(L, ownedMetatableName)
            return 1
        }
    }

    private static let disabledOpen: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        DebugLog.log("[LuaDB] open denied: db permission not granted")
        lua_pushnil(L)
        lua_pushstring(L, "db permission not granted")
        return 2
    }

    private static let disabledSnapshot: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        DebugLog.log("[LuaDB] snapshot denied: db permission not granted")
        lua_pushnil(L)
        lua_pushstring(L, "db permission not granted")
        return 2
    }

    // MARK: - C Functions: methods on db

    /// `db:exec(sql, params?) -> changes | nil, err`
    /// Only valid on owned DB handles — external handles' metatable does not
    /// expose this method.
    private static let dbExec: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        let hid = handleId(L: L, at: 1, metatables: [ownedMetatableName])
        guard hid > 0 else {
            lua_pushnil(L)
            lua_pushstring(L, "db is closed")
            return 2
        }
        guard lua_type(L, 2) == lua_swift_type_string(),
              let sqlCstr = lua_swift_tostring(L, 2) else {
            lua_pushnil(L)
            lua_pushstring(L, "sql must be a string")
            return 2
        }
        let sql = String(cString: sqlCstr)

        let paramsResult = readParams(L: L, paramsIndex: 3)
        guard let params = paramsResult.params else {
            lua_pushnil(L)
            lua_pushstring(L, paramsResult.error ?? "invalid params")
            return 2
        }

        switch PluginDBManager.shared.syncExec(handleId: hid, sql: sql, params: params) {
        case .failure(let err):
            lua_pushnil(L)
            lua_pushstring(L, err.message)
            return 2
        case .success(let changes):
            lua_pushinteger(L, lua_Integer(changes))
            return 1
        }
    }

    /// `db:query(sql, params?) -> rows[] | nil, err`
    private static let dbQuery: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        let hid = handleId(L: L, at: 1, metatables: anyDBMetatables)
        guard hid > 0 else {
            lua_pushnil(L)
            lua_pushstring(L, "db is closed")
            return 2
        }
        guard lua_type(L, 2) == lua_swift_type_string(),
              let sqlCstr = lua_swift_tostring(L, 2) else {
            lua_pushnil(L)
            lua_pushstring(L, "sql must be a string")
            return 2
        }
        let sql = String(cString: sqlCstr)

        let paramsResult = readParams(L: L, paramsIndex: 3)
        guard let params = paramsResult.params else {
            lua_pushnil(L)
            lua_pushstring(L, paramsResult.error ?? "invalid params")
            return 2
        }

        switch PluginDBManager.shared.syncQuery(handleId: hid, sql: sql, params: params) {
        case .failure(let err):
            lua_pushnil(L)
            lua_pushstring(L, err.message)
            return 2
        case .success(let rows):
            lua_createtable(L, Int32(rows.count), 0)
            for (idx, row) in rows.enumerated() {
                pushRow(L, row)
                lua_rawseti(L, -2, lua_Integer(idx + 1))
            }
            return 1
        }
    }

    /// `db:queryOne(sql, params?) -> row|nil | nil, err`
    private static let dbQueryOne: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        let hid = handleId(L: L, at: 1, metatables: anyDBMetatables)
        guard hid > 0 else {
            lua_pushnil(L)
            lua_pushstring(L, "db is closed")
            return 2
        }
        guard lua_type(L, 2) == lua_swift_type_string(),
              let sqlCstr = lua_swift_tostring(L, 2) else {
            lua_pushnil(L)
            lua_pushstring(L, "sql must be a string")
            return 2
        }
        let sql = String(cString: sqlCstr)

        let paramsResult = readParams(L: L, paramsIndex: 3)
        guard let params = paramsResult.params else {
            lua_pushnil(L)
            lua_pushstring(L, paramsResult.error ?? "invalid params")
            return 2
        }

        switch PluginDBManager.shared.syncQueryOne(handleId: hid, sql: sql, params: params) {
        case .failure(let err):
            lua_pushnil(L)
            lua_pushstring(L, err.message)
            return 2
        case .success(let rowOpt):
            if let row = rowOpt {
                pushRow(L, row)
            } else {
                lua_pushnil(L)
            }
            return 1
        }
    }

    /// `db:close() -> true`
    private static let dbClose: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        let hid = handleId(L: L, at: 1, metatables: anyDBMetatables)
        if hid > 0 {
            let pid = pluginId(from: L)
            PluginDBManager.shared.syncClose(pluginId: pid, handleId: hid)
            setHandleId(L: L, at: 1, value: 0, metatables: anyDBMetatables)
        }
        lua_pushboolean(L, 1)
        return 1
    }

    /// `__gc` metamethod — ensures DB is closed when userdata is collected.
    private static let dbGc: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        let hid = handleId(L: L, at: 1, metatables: anyDBMetatables)
        if hid > 0 {
            let pid = pluginId(from: L)
            PluginDBManager.shared.syncClose(pluginId: pid, handleId: hid)
            setHandleId(L: L, at: 1, value: 0, metatables: anyDBMetatables)
        }
        return 0
    }

    // MARK: - Transaction

    /// `db:transaction(fn) -> true, fn-returns...  |  false, err  |  raises`
    /// Owned handles only (external metatable does not expose this method).
    /// Semantics:
    ///   - fn completes normally with truthy first return (or no returns) → COMMIT,
    ///     pushes `true` followed by fn's returns.
    ///   - fn returns `false` or `nil` as first value → ROLLBACK,
    ///     returns `false, err-string` (second return from fn or default).
    ///   - fn raises a Lua error → ROLLBACK, re-raises via `lua_error`.
    private static let dbTransaction: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        let hid = handleId(L: L, at: 1, metatables: [ownedMetatableName])
        guard hid > 0 else {
            lua_pushnil(L)
            lua_pushstring(L, "db is closed")
            return 2
        }
        guard lua_type(L, 2) == lua_swift_type_function() else {
            lua_pushnil(L)
            lua_pushstring(L, "transaction requires a function argument")
            return 2
        }

        // BEGIN
        if case .failure(let err) = PluginDBManager.shared.syncBeginTransaction(handleId: hid) {
            lua_pushnil(L)
            lua_pushstring(L, err.message)
            return 2
        }

        // Call fn. Stack before pcall: self(1), fn(2). We duplicate fn so the
        // original stays at index 2 for debugging symmetry.
        let topBefore = lua_gettop(L)
        lua_pushvalue(L, 2)
        let rc = lua_swift_pcall(L, 0, LUA_MULTRET, 0)

        if rc != LUA_OK {
            // fn errored: rollback, then propagate error (stack top is err msg)
            PluginDBManager.shared.syncRollbackTransaction(handleId: hid)
            return lua_error(L) // does not return
        }

        // fn returned; stack now has nReturns values pushed after topBefore.
        let nReturns = lua_gettop(L) - topBefore

        let firstIsFalsy: Bool = {
            if nReturns == 0 { return false }
            let firstIdx = topBefore + 1
            let t = lua_type(L, firstIdx)
            if t == lua_swift_type_nil() { return true }
            if t == lua_swift_type_boolean() && lua_toboolean(L, firstIdx) == 0 { return true }
            return false
        }()

        if firstIsFalsy {
            PluginDBManager.shared.syncRollbackTransaction(handleId: hid)
            var errMsg = "transaction rolled back"
            if nReturns >= 2, let c = lua_swift_tostring(L, topBefore + 2) {
                errMsg = String(cString: c)
            }
            lua_settop(L, topBefore)
            lua_pushboolean(L, 0)
            lua_pushstring(L, errMsg)
            return 2
        }

        // COMMIT. If it fails, best-effort ROLLBACK and surface error.
        if case .failure(let err) = PluginDBManager.shared.syncCommitTransaction(handleId: hid) {
            PluginDBManager.shared.syncRollbackTransaction(handleId: hid)
            lua_settop(L, topBefore)
            lua_pushnil(L)
            lua_pushstring(L, err.message)
            return 2
        }

        // Success: push `true` before the return values so callers see
        // `true, ret1, ret2, ...`.
        lua_pushboolean(L, 1)                       // stack: ..., ret1..retN, true
        lua_rotate(L, topBefore + 1, 1)             // rotate true to position before ret1
        return Int32(nReturns + 1)
    }

    // MARK: - openExternal implementation

    /// `lingxi.db.openExternal(path) -> userdata | nil, err`
    ///
    /// A path that lies inside this plugin's own snapshots cache (produced by
    /// `lingxi.db.snapshot`) is auto-allowed regardless of `db_external_paths`.
    /// All other paths must match the user-configured whitelist.
    private static let dbOpenExternal: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        guard lua_type(L, 1) == lua_swift_type_string(),
              let cstr = lua_swift_tostring(L, 1) else {
            lua_pushnil(L)
            lua_pushstring(L, "path must be a string")
            return 2
        }
        let path = String(cString: cstr)
        let pid = pluginId(from: L)

        let canonical: String
        if let snap = PluginDBManager.shared.syncResolveSnapshotPath(pluginId: pid, path: path) {
            canonical = snap
        } else {
            let allowed = externalPermissions[pid] ?? []
            guard !allowed.isEmpty else {
                DebugLog.log("[LuaDB] \(pid): openExternal(\(path)) denied: no db_external_paths configured")
                lua_pushnil(L)
                lua_pushstring(L, "no external paths allowed (configure permissions.db_external_paths)")
                return 2
            }
            let validator = PathValidator(allowedPaths: allowed)
            guard let c = validator.validate(path) else {
                DebugLog.log("[LuaDB] \(pid): openExternal(\(path)) denied: not in db_external_paths whitelist")
                lua_pushnil(L)
                lua_pushstring(L, "path not in db_external_paths whitelist")
                return 2
            }
            canonical = c
        }

        switch PluginDBManager.shared.syncOpenExternal(pluginId: pid, canonicalPath: canonical) {
        case .failure(let err):
            DebugLog.log("[LuaDB] \(pid): openExternal(\(canonical)) failed: \(err.message)")
            lua_pushnil(L)
            lua_pushstring(L, err.message)
            return 2
        case .success(let handleId):
            let ud = lua_newuserdatauv(L, MemoryLayout<Int>.size, 0)
            ud?.assumingMemoryBound(to: Int.self).pointee = handleId
            luaL_setmetatable(L, externalMetatableName)
            return 1
        }
    }

    // MARK: - blob constructor

    /// `lingxi.db.blob(str) -> { __blob = true, data = str }`
    ///
    /// A stable marker table that `db:exec`/`db:query` parameter readers
    /// recognize and bind as SQLite BLOB. The string can contain embedded
    /// NULs since Lua strings are byte-safe and `readLuaBytes` uses
    /// `lua_rawlen` instead of C string conventions.
    private static let dbBlob: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        guard lua_type(L, 1) == lua_swift_type_string() else {
            lua_pushnil(L)
            lua_pushstring(L, "lingxi.db.blob(str) requires a string argument")
            return 2
        }
        // Build the marker table: { __blob = true, data = <string at 1> }
        lua_createtable(L, 0, 2)
        lua_pushboolean(L, 1)
        lua_setfield(L, -2, "__blob")
        lua_pushvalue(L, 1)
        lua_setfield(L, -2, "data")
        return 1
    }

    // MARK: - snapshot implementation

    /// `lingxi.db.snapshot(src) -> destPath | nil, err`
    ///
    /// Source must be whitelisted in `db_external_paths`. The returned path
    /// lives under the plugin's cache (`<baseDirectory>/<plugin-id>/snapshots/`)
    /// and is auto-allowed by `openExternal`.
    private static let dbSnapshot: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        guard lua_type(L, 1) == lua_swift_type_string(),
              let cstr = lua_swift_tostring(L, 1) else {
            lua_pushnil(L)
            lua_pushstring(L, "path must be a string")
            return 2
        }
        let path = String(cString: cstr)
        let pid = pluginId(from: L)

        let allowed = externalPermissions[pid] ?? []
        guard !allowed.isEmpty else {
            DebugLog.log("[LuaDB] \(pid): snapshot(\(path)) denied: no db_external_paths configured")
            lua_pushnil(L)
            lua_pushstring(L, "no external paths allowed (configure permissions.db_external_paths)")
            return 2
        }
        let validator = PathValidator(allowedPaths: allowed)
        guard let canonical = validator.validate(path) else {
            DebugLog.log("[LuaDB] \(pid): snapshot(\(path)) denied: not in db_external_paths whitelist")
            lua_pushnil(L)
            lua_pushstring(L, "path not in db_external_paths whitelist")
            return 2
        }

        switch PluginDBManager.shared.syncSnapshotExternal(pluginId: pid, canonicalSourcePath: canonical) {
        case .failure(let err):
            DebugLog.log("[LuaDB] \(pid): snapshot(\(canonical)) failed: \(err.message)")
            lua_pushnil(L)
            lua_pushstring(L, err.message)
            return 2
        case .success(let destPath):
            lua_pushstring(L, destPath)
            return 1
        }
    }
}
