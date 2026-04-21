import AppKit
import CLua
import Foundation

/// Registers `lingxi.*` APIs into a Lua state based on plugin permissions.
nonisolated enum LuaAPI {
    /// Call after `openLibs()` and `LuaSandbox.apply()`.
    /// APIs without permission are registered as stubs that return nil/false and log a warning.
    static func registerAll(state: LuaState, permissions: PermissionConfig, pluginId: String = "") {
        state.createTable()
        if permissions.network {
            registerHTTP(state: state)
        } else {
            registerDisabledHTTP(state: state)
        }
        if permissions.clipboard {
            registerClipboard(state: state)
        } else {
            registerDisabledClipboard(state: state)
        }
        registerStore(state: state, pluginId: pluginId)
        state.setGlobal("lingxi")
    }

    // MARK: - lingxi.http

    private static func registerHTTP(state: LuaState) {
        state.createTable(nrec: 2)
        state.pushFunction(httpGet)
        state.setField("get", at: -2)
        state.pushFunction(httpPost)
        state.setField("post", at: -2)
        state.setField("http", at: -2)
    }

    private static func registerDisabledHTTP(state: LuaState) {
        state.createTable(nrec: 2)
        state.pushFunction(disabledHTTPGet)
        state.setField("get", at: -2)
        state.pushFunction(disabledHTTPPost)
        state.setField("post", at: -2)
        state.setField("http", at: -2)
    }

    // MARK: - lingxi.clipboard

    private static func registerClipboard(state: LuaState) {
        state.createTable(nrec: 2)
        state.pushFunction(clipboardRead)
        state.setField("read", at: -2)
        state.pushFunction(clipboardWrite)
        state.setField("write", at: -2)
        state.setField("clipboard", at: -2)
    }

    private static func registerDisabledClipboard(state: LuaState) {
        state.createTable(nrec: 2)
        state.pushFunction(disabledClipboardRead)
        state.setField("read", at: -2)
        state.pushFunction(disabledClipboardWrite)
        state.setField("write", at: -2)
        state.setField("clipboard", at: -2)
    }

    // MARK: - HTTP C Functions

    private static let httpTimeout: TimeInterval = 10

    /// `lingxi.http.get(url [, headers]) -> {status, body, headers}`
    private static let httpGet: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        guard let urlStr = lua_swift_tostring(L, 1).map({ String(cString: $0) }) else {
            lua_pushstring(L, "lingxi.http.get: first argument must be a URL string")
            return lua_error(L)
        }
        guard let url = URL(string: urlStr) else {
            lua_pushstring(L, "lingxi.http.get: invalid URL")
            return lua_error(L)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = httpTimeout

        if lua_swift_istable(L, 2) != 0 {
            applyHeaders(L, tableIndex: 2, to: &request)
        }

        return executeRequest(L, request: request)
    }

    /// `lingxi.http.post(url, body [, content_type]) -> {status, body, headers}`
    private static let httpPost: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        guard let urlStr = lua_swift_tostring(L, 1).map({ String(cString: $0) }) else {
            lua_pushstring(L, "lingxi.http.post: first argument must be a URL string")
            return lua_error(L)
        }
        guard let url = URL(string: urlStr) else {
            lua_pushstring(L, "lingxi.http.post: invalid URL")
            return lua_error(L)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = httpTimeout

        if let bodyStr = lua_swift_tostring(L, 2).map({ String(cString: $0) }) {
            request.httpBody = bodyStr.data(using: .utf8)
        }

        if let contentType = lua_swift_tostring(L, 3).map({ String(cString: $0) }) {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        return executeRequest(L, request: request)
    }

    // Lua's C API is synchronous, so we must block until the response arrives.
    // This runs inside a LuaSearchProvider actor; the actor's timeout (default 5s)
    // caps the wall-clock wait from the caller's perspective, and the URLRequest
    // timeout (10s) prevents an unbounded thread hold.
    private static func executeRequest(_ L: OpaquePointer, request: URLRequest) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var httpResponse: HTTPURLResponse?
        var requestError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            httpResponse = response as? HTTPURLResponse
            requestError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = requestError {
            lua_pushstring(L, "HTTP request failed: \(error.localizedDescription)")
            return lua_error(L)
        }

        lua_createtable(L, 0, 3)

        lua_pushinteger(L, lua_Integer(httpResponse?.statusCode ?? 0))
        lua_setfield(L, -2, "status")

        let body = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        lua_pushstring(L, body)
        lua_setfield(L, -2, "body")

        lua_createtable(L, 0, Int32(httpResponse?.allHeaderFields.count ?? 0))
        if let headers = httpResponse?.allHeaderFields {
            for (key, value) in headers {
                lua_pushstring(L, "\(value)")
                lua_setfield(L, -2, "\(key)")
            }
        }
        lua_setfield(L, -2, "headers")

        return 1
    }

    private static func applyHeaders(_ L: OpaquePointer, tableIndex: Int32, to request: inout URLRequest) {
        let absIdx = lua_absindex(L, tableIndex)
        lua_pushnil(L)
        while lua_next(L, absIdx) != 0 {
            if let key = lua_swift_tostring(L, -2).map({ String(cString: $0) }),
               let value = lua_swift_tostring(L, -1).map({ String(cString: $0) }) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            lua_swift_pop(L, 1)
        }
    }

    // MARK: - Clipboard C Functions

    /// `lingxi.clipboard.read() -> string or nil`
    private static let clipboardRead: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        let text = NSPasteboard.general.string(forType: .string)
        if let text {
            lua_pushstring(L, text)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    /// `lingxi.clipboard.write(text) -> boolean`
    /// Marks the write as transient to prevent ClipboardStore from re-capturing it.
    private static let clipboardWrite: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        guard let text = lua_swift_tostring(L, 1).map({ String(cString: $0) }) else {
            lua_pushboolean(L, 0)
            return 1
        }
        let pb = ClipboardStore.prepareTransientPasteboard(types: [.string])
        pb.setString(text, forType: .string)
        lua_pushboolean(L, 1)
        return 1
    }

    // MARK: - Disabled Stubs

    private static let disabledHTTPGet: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        DebugLog.log("[LuaAPI] lingxi.http.get denied: network permission not granted")
        lua_pushnil(L)
        return 1
    }

    private static let disabledHTTPPost: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        DebugLog.log("[LuaAPI] lingxi.http.post denied: network permission not granted")
        lua_pushnil(L)
        return 1
    }

    private static let disabledClipboardRead: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        DebugLog.log("[LuaAPI] lingxi.clipboard.read denied: clipboard permission not granted")
        lua_pushnil(L)
        return 1
    }

    private static let disabledClipboardWrite: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        DebugLog.log("[LuaAPI] lingxi.clipboard.write denied: clipboard permission not granted")
        lua_pushboolean(L, 0)
        return 1
    }

    // MARK: - lingxi.store

    private static func registerStore(state: LuaState, pluginId: String) {
        // Store pluginId as a hidden field on the lingxi table so C callbacks can retrieve it.
        state.push(pluginId)
        state.setField("_pluginId", at: -2)

        state.createTable(nrec: 3)
        state.pushFunction(storeGet)
        state.setField("get", at: -2)
        state.pushFunction(storeSet)
        state.setField("set", at: -2)
        state.pushFunction(storeDelete)
        state.setField("delete", at: -2)
        state.setField("store", at: -2)
    }

    /// Retrieve the plugin ID from the `lingxi._pluginId` field.
    private static func pluginId(from L: OpaquePointer) -> String {
        lua_getglobal(L, "lingxi")
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

    /// `lingxi.store.get(key) -> any | nil`
    private static let storeGet: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        guard let key = lua_swift_tostring(L, 1).map({ String(cString: $0) }) else {
            lua_pushnil(L)
            return 1
        }
        let pid = pluginId(from: L)
        let value = StoreManager.shared.syncGet(pluginId: pid, key: key)
        if let value {
            pushSwiftValue(L, value: value)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    /// `lingxi.store.set(key, value) -> boolean`
    private static let storeSet: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        guard let key = lua_swift_tostring(L, 1).map({ String(cString: $0) }) else {
            lua_pushboolean(L, 0)
            return 1
        }
        let pid = pluginId(from: L)
        let value = luaValueToSwift(L, index: 2)
        let ok = StoreManager.shared.syncSet(pluginId: pid, key: key, value: value)
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    /// `lingxi.store.delete(key) -> boolean`
    private static let storeDelete: @convention(c) (OpaquePointer?) -> Int32 = { L in
        guard let L else { return 0 }
        guard let key = lua_swift_tostring(L, 1).map({ String(cString: $0) }) else {
            lua_pushboolean(L, 0)
            return 1
        }
        let pid = pluginId(from: L)
        let ok = StoreManager.shared.syncDelete(pluginId: pid, key: key)
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    // MARK: - Lua <-> Swift value conversion

    /// Convert a Lua value at the given index to a Swift JSON-compatible value.
    private static func luaValueToSwift(_ L: OpaquePointer, index: Int32) -> Any {
        let absIdx = lua_absindex(L, index)
        switch lua_type(L, absIdx) {
        case lua_swift_type_string():
            if let cstr = lua_swift_tostring(L, absIdx) {
                return String(cString: cstr)
            }
            return ""
        case lua_swift_type_number():
            return lua_swift_tonumber(L, absIdx)
        case lua_swift_type_boolean():
            return lua_toboolean(L, absIdx) != 0
        case lua_swift_type_table():
            return luaTableToSwift(L, index: absIdx)
        case lua_swift_type_nil():
            return NSNull()
        default:
            return String(describing: "unsupported Lua type \(lua_type(L, absIdx))")
        }
    }

    /// Convert a Lua table to a Swift Array or Dictionary.
    private static func luaTableToSwift(_ L: OpaquePointer, index: Int32) -> Any {
        let absIdx = lua_absindex(L, index)
        var dict: [String: Any] = [:]
        var array: [Any] = []
        var isArray = true
        var maxIndex = 0

        lua_pushnil(L)
        while lua_next(L, absIdx) != 0 {
            let keyType = lua_type(L, -2)
            if keyType == lua_swift_type_number() {
                let idx = Int(lua_swift_tointeger(L, -2))
                if idx > 0 {
                    array.append(luaValueToSwift(L, index: -1))
                    maxIndex = max(maxIndex, idx)
                } else {
                    isArray = false
                }
            } else {
                isArray = false
            }
            lua_swift_pop(L, 1)
        }

        if isArray && maxIndex == array.count {
            return array
        }

        // Convert to dictionary (string keys)
        lua_pushnil(L)
        while lua_next(L, absIdx) != 0 {
            if let cstr = lua_swift_tostring(L, -2) {
                let key = String(cString: cstr)
                dict[key] = luaValueToSwift(L, index: -1)
            }
            lua_swift_pop(L, 1)
        }
        return dict
    }

    /// Push a Swift JSON-compatible value onto the Lua stack.
    private static func pushSwiftValue(_ L: OpaquePointer, value: Any) {
        switch value {
        case let s as String:
            lua_pushstring(L, s)
        case let b as Bool:
            lua_pushboolean(L, b ? 1 : 0)
        case let d as Double:
            lua_pushnumber(L, d)
        case let i as Int:
            lua_pushinteger(L, lua_Integer(i))
        case let arr as [Any]:
            lua_createtable(L, Int32(arr.count), 0)
            for (idx, elem) in arr.enumerated() {
                pushSwiftValue(L, value: elem)
                lua_rawseti(L, -2, lua_Integer(idx + 1))
            }
        case let dict as [String: Any]:
            lua_createtable(L, 0, Int32(dict.count))
            for (k, v) in dict {
                lua_pushstring(L, k)
                pushSwiftValue(L, value: v)
                lua_settable(L, -3)
            }
        case is NSNull:
            lua_pushnil(L)
        default:
            lua_pushstring(L, String(describing: value))
        }
    }
}
