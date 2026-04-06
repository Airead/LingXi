import CLua

enum LuaError: Error, CustomStringConvertible {
    case runtimeError(String)
    case fileError(String)
    case syntaxError(String)
    case memoryError
    case unknown(Int32)

    var description: String {
        switch self {
        case .runtimeError(let msg): "Lua runtime error: \(msg)"
        case .fileError(let msg): "Lua file error: \(msg)"
        case .syntaxError(let msg): "Lua syntax error: \(msg)"
        case .memoryError: "Lua memory allocation error"
        case .unknown(let code): "Lua error (code \(code))"
        }
    }
}

/// Swift wrapper around a Lua state. Not thread-safe — access from a single thread only.
nonisolated final class LuaState: @unchecked Sendable {
    private let L: OpaquePointer

    init() {
        L = luaL_newstate()
    }

    deinit {
        lua_close(L)
    }

    // MARK: - Libraries

    func openLibs() {
        lua_swift_openlibs(L)
    }

    // MARK: - Execute

    func loadFile(_ path: String) throws {
        let status = luaL_loadfilex(L, path, nil)
        if status != LUA_OK {
            throw luaError(status: status)
        }
    }

    func doFile(_ path: String) throws {
        try loadFile(path)
        try pcall(nargs: 0, nresults: Int32(LUA_MULTRET))
    }

    func doString(_ code: String) throws {
        let status = luaL_loadstring(L, code)
        if status != LUA_OK {
            throw luaError(status: status)
        }
        try pcall(nargs: 0, nresults: Int32(LUA_MULTRET))
    }

    func pcall(nargs: Int32, nresults: Int32, errfunc: Int32 = 0) throws {
        let status = lua_swift_pcall(L, nargs, nresults, errfunc)
        if status != LUA_OK {
            throw luaError(status: status)
        }
    }

    // MARK: - Stack Operations

    var top: Int32 {
        lua_gettop(L)
    }

    func pop(_ n: Int32 = 1) {
        lua_swift_pop(L, n)
    }

    // MARK: - Push

    func push(_ value: String) {
        lua_pushstring(L, value)
    }

    func push(_ value: Double) {
        lua_pushnumber(L, value)
    }

    func push(_ value: Int) {
        lua_pushinteger(L, lua_Integer(value))
    }

    func push(_ value: Bool) {
        lua_pushboolean(L, value ? 1 : 0)
    }

    func pushNil() {
        lua_pushnil(L)
    }

    func pushFunction(_ fn: @convention(c) (OpaquePointer?) -> Int32) {
        lua_swift_pushcfunction(L, fn)
    }

    // MARK: - Get from stack

    func toString(at index: Int32) -> String? {
        guard lua_type(L, index) == lua_swift_type_string() else { return nil }
        guard let cstr = lua_swift_tostring(L, index) else { return nil }
        return String(cString: cstr)
    }

    func toNumber(at index: Int32) -> Double? {
        guard lua_type(L, index) == lua_swift_type_number() else { return nil }
        return lua_swift_tonumber(L, index)
    }

    func toInt(at index: Int32) -> Int? {
        guard lua_type(L, index) == lua_swift_type_number() else { return nil }
        return Int(lua_swift_tointeger(L, index))
    }

    func toBool(at index: Int32) -> Bool {
        lua_toboolean(L, index) != 0
    }

    func isTable(at index: Int32) -> Bool {
        lua_swift_istable(L, index) != 0
    }

    func isFunction(at index: Int32) -> Bool {
        lua_type(L, index) == lua_swift_type_function()
    }

    func isNil(at index: Int32) -> Bool {
        lua_swift_isnil(L, index) != 0
    }

    func type(at index: Int32) -> Int32 {
        lua_type(L, index)
    }

    // MARK: - Table Operations

    func createTable(narr: Int32 = 0, nrec: Int32 = 0) {
        lua_createtable(L, narr, nrec)
    }

    func setField(_ name: String, at index: Int32) {
        lua_setfield(L, index, name)
    }

    func getField(_ name: String, at index: Int32) {
        lua_getfield(L, index, name)
    }

    func getGlobal(_ name: String) {
        lua_getglobal(L, name)
    }

    func setGlobal(_ name: String) {
        lua_setglobal(L, name)
    }

    /// Iterate over an integer-keyed (array-like) table at the given stack index.
    /// Calls the closure for each element (pushed on top of the stack).
    /// The closure must not modify the stack.
    func iterateArray(at index: Int32, body: () throws -> Void) rethrows {
        let absIdx = lua_absindex(L, index)
        let len = lua_rawlen(L, absIdx)
        guard len > 0 else { return }
        for i: lua_Unsigned in 1...len {
            lua_rawgeti(L, absIdx, lua_Integer(i))
            try body()
            pop()
        }
    }

    func stringField(_ name: String, at index: Int32) -> String? {
        let absIdx = lua_absindex(L, index)
        getField(name, at: absIdx)
        let value = toString(at: -1)
        pop()
        return value
    }

    func numberField(_ name: String, at index: Int32) -> Double? {
        let absIdx = lua_absindex(L, index)
        getField(name, at: absIdx)
        let value = toNumber(at: -1)
        pop()
        return value
    }

    // MARK: - Global Table Manipulation

    func removeGlobalField(table: String, field: String) {
        getGlobal(table)
        if isTable(at: -1) {
            pushNil()
            setField(field, at: -2)
        }
        pop()
    }

    func removeGlobal(_ name: String) {
        pushNil()
        setGlobal(name)
    }

    // MARK: - Error Helpers

    private func luaError(status: Int32) -> LuaError {
        let msg = toString(at: -1) ?? "unknown error"
        pop()
        switch status {
        case LUA_ERRRUN: return .runtimeError(msg)
        case LUA_ERRSYNTAX: return .syntaxError(msg)
        case LUA_ERRMEM: return .memoryError
        case LUA_ERRFILE: return .fileError(msg)
        default: return .unknown(status)
        }
    }
}

// MARK: - LUA_ERRFILE not in lua.h, defined in lauxlib.h
private let LUA_ERRFILE = LUA_ERRERR + 1
