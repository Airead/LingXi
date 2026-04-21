import AppKit
import Foundation
import Testing
@testable import LingXi

struct LuaAPITests {
    private func makeState(permissions: PermissionConfig = .default) -> LuaState {
        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)
        LuaAPI.registerAll(state: state, permissions: permissions)
        return state
    }

    // MARK: - lingxi table structure

    @Test func lingxiTableExists() throws {
        let state = makeState()
        state.getGlobal("lingxi")
        #expect(state.isTable(at: -1))
        state.pop()
    }

    @Test func httpSubtableExists() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        try state.doString("assert(type(lingxi.http) == 'table')")
    }

    @Test func clipboardSubtableExists() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        try state.doString("assert(type(lingxi.clipboard) == 'table')")
    }

    @Test func httpGetIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        try state.doString("assert(type(lingxi.http.get) == 'function')")
    }

    @Test func httpPostIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        try state.doString("assert(type(lingxi.http.post) == 'function')")
    }

    @Test func clipboardReadIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        try state.doString("assert(type(lingxi.clipboard.read) == 'function')")
    }

    @Test func clipboardWriteIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        try state.doString("assert(type(lingxi.clipboard.write) == 'function')")
    }

    // MARK: - lingxi.http.get

    @Test func httpGetInvalidURL() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        #expect(throws: LuaError.self) {
            try state.doString("""
                lingxi.http.get("not a valid url %%%")
            """)
        }
    }

    @Test func httpGetMissingArgument() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        #expect(throws: LuaError.self) {
            try state.doString("lingxi.http.get()")
        }
    }

    // MARK: - lingxi.http.post

    @Test func httpPostInvalidURL() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        #expect(throws: LuaError.self) {
            try state.doString("""
                lingxi.http.post("not a valid url %%%", "body")
            """)
        }
    }

    @Test func httpPostMissingArgument() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        #expect(throws: LuaError.self) {
            try state.doString("lingxi.http.post()")
        }
    }

    // MARK: - lingxi.clipboard

    @Test @MainActor func clipboardWriteAndRead() throws {
        let pb = NSPasteboard(name: .init("LuaAPITests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        // Use the real pasteboard for this test since the C callback uses NSPasteboard.general.
        // Instead, we test the Lua-level write/read cycle.
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        try state.doString("""
            lingxi.clipboard.write("lua-test-value-42")
            local text = lingxi.clipboard.read()
            assert(text == "lua-test-value-42", "expected lua-test-value-42, got " .. tostring(text))
        """)
        // Cleanup: restore pasteboard
        let general = NSPasteboard.general
        general.clearContents()
    }

    @Test func clipboardWriteReturnsTrueOnSuccess() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        try state.doString("""
            local ok = lingxi.clipboard.write("test")
            assert(ok == true)
        """)
        NSPasteboard.general.clearContents()
    }

    @Test func clipboardWriteReturnsFalseOnNil() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        try state.doString("""
            local ok = lingxi.clipboard.write(nil)
            assert(ok == false)
        """)
    }

    @Test func clipboardReadReturnsNilWhenEmpty() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false))
        // Clear the pasteboard first
        let general = NSPasteboard.general
        general.clearContents()
        try state.doString("""
            local text = lingxi.clipboard.read()
            assert(text == nil, "expected nil, got " .. tostring(text))
        """)
    }

    // MARK: - Permission-based API gating

    @Test func httpDisabledReturnsNil() throws {
        let perms = PermissionConfig(network: false, clipboard: true, filesystem: [], shell: [], notify: false)
        let state = makeState(permissions: perms)
        try state.doString("""
            local result = lingxi.http.get("https://example.com")
            assert(result == nil, "expected nil, got " .. tostring(result))
        """)
    }

    @Test func clipboardDisabledReadReturnsNil() throws {
        let perms = PermissionConfig(network: true, clipboard: false, filesystem: [], shell: [], notify: false)
        let state = makeState(permissions: perms)
        try state.doString("""
            local text = lingxi.clipboard.read()
            assert(text == nil, "expected nil, got " .. tostring(text))
        """)
    }

    @Test func clipboardDisabledWriteReturnsFalse() throws {
        let perms = PermissionConfig(network: true, clipboard: false, filesystem: [], shell: [], notify: false)
        let state = makeState(permissions: perms)
        try state.doString("""
            local ok = lingxi.clipboard.write("test")
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
    }

    @Test func lingxiTableStillCreatedWhenNoPermissions() throws {
        let perms = PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false)
        let state = makeState(permissions: perms)
        state.getGlobal("lingxi")
        #expect(state.isTable(at: -1))
        state.pop()
    }
}
