import AppKit
import Foundation
import Testing
@testable import LingXi

struct LuaAPITests {
    private func makeState(permissions: PermissionConfig = .default, pluginId: String = "test.plugin") -> LuaState {
        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)
        LuaAPI.registerAll(state: state, permissions: permissions, pluginId: pluginId)
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

    // MARK: - lingxi.store

    @Test func storeSubtableExists() throws {
        let state = makeState()
        try state.doString("assert(type(lingxi.store) == 'table')")
    }

    @Test func storeGetIsFunction() throws {
        let state = makeState()
        try state.doString("assert(type(lingxi.store.get) == 'function')")
    }

    @Test func storeSetIsFunction() throws {
        let state = makeState()
        try state.doString("assert(type(lingxi.store.set) == 'function')")
    }

    @Test func storeDeleteIsFunction() throws {
        let state = makeState()
        try state.doString("assert(type(lingxi.store.delete) == 'function')")
    }

    @Test func storeSetAndGetString() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = StoreManager(baseDirectory: tempDir)

        let state = makeState(pluginId: "test.store.string")
        try state.doString("""
            lingxi.store.set("name", "hello")
            local value = lingxi.store.get("name")
            assert(value == "hello", "expected hello, got " .. tostring(value))
        """)
    }

    @Test func storeSetAndGetNumber() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = StoreManager(baseDirectory: tempDir)

        let state = makeState(pluginId: "test.store.number")
        try state.doString("""
            lingxi.store.set("count", 42)
            local value = lingxi.store.get("count")
            assert(value == 42, "expected 42, got " .. tostring(value))
        """)
    }

    @Test func storeSetAndGetBoolean() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = StoreManager(baseDirectory: tempDir)

        let state = makeState(pluginId: "test.store.bool")
        try state.doString("""
            lingxi.store.set("enabled", true)
            local value = lingxi.store.get("enabled")
            assert(value == true, "expected true, got " .. tostring(value))
        """)
    }

    @Test func storeSetAndGetTable() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = StoreManager(baseDirectory: tempDir)

        let state = makeState(pluginId: "test.store.table")
        try state.doString("""
            lingxi.store.set("data", {name = "test", value = 123})
            local data = lingxi.store.get("data")
            assert(type(data) == "table", "expected table, got " .. type(data))
            assert(data.name == "test", "expected test, got " .. tostring(data.name))
            assert(data.value == 123, "expected 123, got " .. tostring(data.value))
        """)
    }

    @Test func storeDeleteRemovesKey() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = StoreManager(baseDirectory: tempDir)

        let state = makeState(pluginId: "test.store.delete")
        try state.doString("""
            lingxi.store.set("temp", "value")
            local ok = lingxi.store.delete("temp")
            assert(ok == true, "expected true, got " .. tostring(ok))
            local value = lingxi.store.get("temp")
            assert(value == nil, "expected nil, got " .. tostring(value))
        """)
    }

    @Test func storeGetMissingReturnsNil() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = StoreManager(baseDirectory: tempDir)

        let state = makeState(pluginId: "test.store.missing")
        try state.doString("""
            local value = lingxi.store.get("nonexistent")
            assert(value == nil, "expected nil, got " .. tostring(value))
        """)
    }

    @Test func storePersistsAcrossStates() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = StoreManager(baseDirectory: tempDir)

        let state1 = makeState(pluginId: "test.store.persist")
        try state1.doString("lingxi.store.set(\"counter\", 5)")

        let state2 = makeState(pluginId: "test.store.persist")
        try state2.doString("""
            local value = lingxi.store.get("counter")
            assert(value == 5, "expected 5, got " .. tostring(value))
        """)
    }

    @Test func storeIsIsolatedByPluginId() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = StoreManager(baseDirectory: tempDir)

        let stateA = makeState(pluginId: "plugin.a")
        try stateA.doString("lingxi.store.set(\"key\", \"value-a\")")

        let stateB = makeState(pluginId: "plugin.b")
        try stateB.doString("""
            local value = lingxi.store.get("key")
            assert(value == nil, "expected nil (isolated), got " .. tostring(value))
        """)
    }

    @Test func storeSetReturnsTrue() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = StoreManager(baseDirectory: tempDir)

        let state = makeState(pluginId: "test.store.set.ok")
        try state.doString("""
            local ok = lingxi.store.set("key", "value")
            assert(ok == true, "expected true, got " .. tostring(ok))
        """)
    }

    @Test func storeSetAndGetArray() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = StoreManager(baseDirectory: tempDir)

        let state = makeState(pluginId: "test.store.array")
        try state.doString("""
            lingxi.store.set("list", {"one", "two", "three"})
            local list = lingxi.store.get("list")
            assert(type(list) == "table", "expected table, got " .. type(list))
            assert(list[1] == "one", "expected one, got " .. tostring(list[1]))
            assert(list[2] == "two", "expected two, got " .. tostring(list[2]))
            assert(list[3] == "three", "expected three, got " .. tostring(list[3]))
        """)
    }

    // MARK: - lingxi.file

    @Test func fileSubtableExists() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false))
        try state.doString("assert(type(lingxi.file) == 'table')")
    }

    @Test func fileReadIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false))
        try state.doString("assert(type(lingxi.file.read) == 'function')")
    }

    @Test func fileWriteIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false))
        try state.doString("assert(type(lingxi.file.write) == 'function')")
    }

    @Test func fileListIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false))
        try state.doString("assert(type(lingxi.file.list) == 'function')")
    }

    @Test func fileExistsIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false))
        try state.doString("assert(type(lingxi.file.exists) == 'function')")
    }

    @Test func fileWriteAndRead() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false),
            pluginId: "test.file.write-read"
        )
        let filePath = tempDir.appendingPathComponent("test.txt").path
        try state.doString("""
            local ok = lingxi.file.write("\(filePath)", "hello world")
            assert(ok == true, "expected true, got " .. tostring(ok))
            local content = lingxi.file.read("\(filePath)")
            assert(content == "hello world", "expected hello world, got " .. tostring(content))
        """)
    }

    @Test func fileExistsReturnsTrueForExistingFile() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("exists.txt").path
        try "test".write(toFile: filePath, atomically: true, encoding: .utf8)

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false),
            pluginId: "test.file.exists"
        )
        try state.doString("""
            local exists = lingxi.file.exists("\(filePath)")
            assert(exists == true, "expected true, got " .. tostring(exists))
        """)
    }

    @Test func fileExistsReturnsFalseForMissingFile() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false),
            pluginId: "test.file.exists-missing"
        )
        try state.doString("""
            local exists = lingxi.file.exists("\(tempDir.path)/missing.txt")
            assert(exists == false, "expected false, got " .. tostring(exists))
        """)
    }

    @Test func fileListReturnsDirectoryContents() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        try "file1".write(toFile: tempDir.appendingPathComponent("file1.txt").path, atomically: true, encoding: .utf8)
        try "file2".write(toFile: tempDir.appendingPathComponent("file2.txt").path, atomically: true, encoding: .utf8)

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false),
            pluginId: "test.file.list"
        )
        try state.doString("""
            local entries = lingxi.file.list("\(tempDir.path)")
            assert(type(entries) == "table", "expected table, got " .. type(entries))
            assert(#entries == 3, "expected 3 entries, got " .. tostring(#entries))
        """)
    }

    @Test func fileDeniedOutsideWhitelist() throws {
        let allowedDir = makeTestTempDir()
        let deniedDir = makeTestTempDir()
        defer {
            try? FileManager.default.removeItem(at: allowedDir)
            try? FileManager.default.removeItem(at: deniedDir)
        }

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [allowedDir.path], shell: [], notify: false),
            pluginId: "test.file.denied"
        )
        try state.doString("""
            local ok = lingxi.file.write("\(deniedDir.path)/hacked.txt", "bad")
            assert(ok == false, "expected false, got " .. tostring(ok))
            local content = lingxi.file.read("\(deniedDir.path)/hacked.txt")
            assert(content == nil, "expected nil, got " .. tostring(content))
        """)
    }

    @Test func fileDisabledReturnsNilOrFalse() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false))
        try state.doString("""
            local content = lingxi.file.read("/tmp/test.txt")
            assert(content == nil, "expected nil, got " .. tostring(content))
            local ok = lingxi.file.write("/tmp/test.txt", "test")
            assert(ok == false, "expected false, got " .. tostring(ok))
            local exists = lingxi.file.exists("/tmp/test.txt")
            assert(exists == false, "expected false, got " .. tostring(exists))
            local list = lingxi.file.list("/tmp")
            assert(list == nil, "expected nil, got " .. tostring(list))
        """)
    }

    @Test func fileReadReturnsNilForMissingFile() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false),
            pluginId: "test.file.read-missing"
        )
        try state.doString("""
            local content = lingxi.file.read("\(tempDir.path)/nonexistent.txt")
            assert(content == nil, "expected nil, got " .. tostring(content))
        """)
    }

    // MARK: - lingxi.shell

    @Test func shellSubtableExists() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false))
        try state.doString("assert(type(lingxi.shell) == 'table')")
    }

    @Test func shellExecIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false))
        try state.doString("assert(type(lingxi.shell.exec) == 'function')")
    }

    @Test func shellExecEcho() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false))
        try state.doString("""
            local result = lingxi.shell.exec("echo hello")
            assert(type(result) == "table", "expected table, got " .. type(result))
            assert(result.exitCode == 0, "expected exitCode 0, got " .. tostring(result.exitCode))
            assert(result.stdout == "hello\\n", "expected 'hello\\\\n', got '" .. tostring(result.stdout) .. "'")
        """)
    }

    @Test func shellExecDeniedCommand() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false))
        try state.doString("""
            local result = lingxi.shell.exec("rm -rf /")
            assert(type(result) == "table", "expected table, got " .. type(result))
            assert(result.exitCode == -1, "expected exitCode -1, got " .. tostring(result.exitCode))
            assert(result.stderr:find("not in shell whitelist") ~= nil, "expected whitelist error, got " .. tostring(result.stderr))
        """)
    }

    @Test func shellExecDisabled() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false))
        try state.doString("""
            local result = lingxi.shell.exec("echo hello")
            assert(type(result) == "table", "expected table, got " .. type(result))
            assert(result.exitCode == -1, "expected exitCode -1, got " .. tostring(result.exitCode))
            assert(result.stderr:find("shell permission not granted") ~= nil, "expected permission error, got " .. tostring(result.stderr))
        """)
    }

    @Test func shellExecAbsolutePath() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false))
        try state.doString("""
            local result = lingxi.shell.exec("/bin/echo hello")
            assert(type(result) == "table", "expected table, got " .. type(result))
            assert(result.exitCode == 0, "expected exitCode 0, got " .. tostring(result.exitCode))
            assert(result.stdout == "hello\\n", "expected 'hello\\\\n', got '" .. tostring(result.stdout) .. "'")
        """)
    }

    @Test func shellExecMissingArgument() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false))
        try state.doString("""
            local result = lingxi.shell.exec()
            assert(type(result) == "table", "expected table, got " .. type(result))
            assert(result.exitCode == -1, "expected exitCode -1, got " .. tostring(result.exitCode))
        """)
    }
}
