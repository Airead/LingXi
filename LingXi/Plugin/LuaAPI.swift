import AppKit
import CLua
import Foundation

/// Registers `lingxi.*` APIs into a Lua state based on plugin permissions.
nonisolated enum LuaAPI {
    /// Call after `openLibs()` and `LuaSandbox.apply()`.
    /// Only registers APIs that the plugin has permission to use.
    static func registerAll(state: LuaState, permissions: PermissionConfig) {
        state.createTable()
        if permissions.network {
            registerHTTP(state: state)
        }
        if permissions.clipboard {
            registerClipboard(state: state)
        }
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

    // MARK: - lingxi.clipboard

    private static func registerClipboard(state: LuaState) {
        state.createTable(nrec: 2)
        state.pushFunction(clipboardRead)
        state.setField("read", at: -2)
        state.pushFunction(clipboardWrite)
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
}
