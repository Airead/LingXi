import AppKit
import CLua
import Foundation
import Testing
@testable import LingXi

struct LuaAPITests {
    private func makeState(permissions: PermissionConfig = PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: true, webview: false, cache: false, db: false), pluginId: String = "test.plugin") -> LuaState {
        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)
        LuaAPI.registerAll(state: state, permissions: permissions, pluginId: pluginId, pluginDir: "")
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
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.http) == 'table')")
    }

    @Test func clipboardSubtableExists() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.clipboard) == 'table')")
    }

    @Test func httpGetIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.http.get) == 'function')")
    }

    @Test func httpPostIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.http.post) == 'function')")
    }

    @Test func clipboardReadIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.clipboard.read) == 'function')")
    }

    @Test func clipboardWriteIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.clipboard.write) == 'function')")
    }

    // MARK: - lingxi.http.get

    @Test func httpGetInvalidURL() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        #expect(throws: LuaError.self) {
            try state.doString("""
                lingxi.http.get("not a valid url %%%")
            """)
        }
    }

    @Test func httpGetMissingArgument() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        #expect(throws: LuaError.self) {
            try state.doString("lingxi.http.get()")
        }
    }

    // MARK: - lingxi.http.post

    @Test func httpPostInvalidURL() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        #expect(throws: LuaError.self) {
            try state.doString("""
                lingxi.http.post("not a valid url %%%", "body")
            """)
        }
    }

    @Test func httpPostMissingArgument() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        #expect(throws: LuaError.self) {
            try state.doString("lingxi.http.post()")
        }
    }

    // MARK: - lingxi.clipboard

    @Test @MainActor func clipboardWriteAndRead() throws {
        let pb = NSPasteboard(name: .init("LuaAPITests-\(UUID().uuidString)"))
        defer {
            pb.releaseGlobally()
            LuaAPI.testingPasteboard = nil
        }
        LuaAPI.testingPasteboard = pb

        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            lingxi.clipboard.write("lua-test-value-42")
            local text = lingxi.clipboard.read()
            assert(text == "lua-test-value-42", "expected lua-test-value-42, got " .. tostring(text))
        """)
    }

    @Test func clipboardWriteReturnsTrueOnSuccess() throws {
        let pb = NSPasteboard(name: .init("LuaAPITests-write-\(UUID().uuidString)"))
        defer {
            pb.releaseGlobally()
            LuaAPI.testingPasteboard = nil
        }
        LuaAPI.testingPasteboard = pb

        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local ok = lingxi.clipboard.write("test")
            assert(ok == true)
        """)
    }

    @Test func clipboardWriteReturnsFalseOnNil() throws {
        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local ok = lingxi.clipboard.write(nil)
            assert(ok == false)
        """)
    }

    @Test func clipboardReadReturnsNilWhenEmpty() throws {
        let pb = NSPasteboard(name: .init("LuaAPITests-read-\(UUID().uuidString)"))
        defer {
            pb.releaseGlobally()
            LuaAPI.testingPasteboard = nil
        }
        LuaAPI.testingPasteboard = pb

        let state = makeState(permissions: PermissionConfig(network: true, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local text = lingxi.clipboard.read()
            assert(text == nil, "expected nil, got " .. tostring(text))
        """)
    }

    // MARK: - Permission-based API gating

    @Test func httpDisabledReturnsNil() throws {
        let perms = PermissionConfig(network: false, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false)
        let state = makeState(permissions: perms)
        try state.doString("""
            local result = lingxi.http.get("https://example.com")
            assert(result == nil, "expected nil, got " .. tostring(result))
        """)
    }

    @Test func clipboardDisabledReadReturnsNil() throws {
        let perms = PermissionConfig(network: true, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false)
        let state = makeState(permissions: perms)
        try state.doString("""
            local text = lingxi.clipboard.read()
            assert(text == nil, "expected nil, got " .. tostring(text))
        """)
    }

    @Test func clipboardDisabledWriteReturnsFalse() throws {
        let perms = PermissionConfig(network: true, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false)
        let state = makeState(permissions: perms)
        try state.doString("""
            local ok = lingxi.clipboard.write("test")
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
    }

    @Test func lingxiTableStillCreatedWhenNoPermissions() throws {
        let perms = PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false)
        let state = makeState(permissions: perms)
        state.getGlobal("lingxi")
        #expect(state.isTable(at: -1))
        state.pop()
    }

    @Test func storeDisabledGetReturnsNil() throws {
        let perms = PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false)
        let state = makeState(permissions: perms)
        try state.doString("""
            local value = lingxi.store.get("key")
            assert(value == nil, "expected nil, got " .. tostring(value))
        """)
    }

    @Test func storeDisabledSetReturnsFalse() throws {
        let perms = PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false)
        let state = makeState(permissions: perms)
        try state.doString("""
            local ok = lingxi.store.set("key", "value")
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
    }

    @Test func storeDisabledDeleteReturnsFalse() throws {
        let perms = PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false)
        let state = makeState(permissions: perms)
        try state.doString("""
            local ok = lingxi.store.delete("key")
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
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
        _ = StoreManager(baseDirectory: tempDir)

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
        _ = StoreManager(baseDirectory: tempDir)

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
        _ = StoreManager(baseDirectory: tempDir)

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
        _ = StoreManager(baseDirectory: tempDir)

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
        _ = StoreManager(baseDirectory: tempDir)

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
        _ = StoreManager(baseDirectory: tempDir)

        let state = makeState(pluginId: "test.store.missing")
        try state.doString("""
            local value = lingxi.store.get("nonexistent")
            assert(value == nil, "expected nil, got " .. tostring(value))
        """)
    }

    @Test func storePersistsAcrossStates() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        _ = StoreManager(baseDirectory: tempDir)

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
        _ = StoreManager(baseDirectory: tempDir)

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
        _ = StoreManager(baseDirectory: tempDir)

        let state = makeState(pluginId: "test.store.set.ok")
        try state.doString("""
            local ok = lingxi.store.set("key", "value")
            assert(ok == true, "expected true, got " .. tostring(ok))
        """)
    }

    @Test func storeSetAndGetArray() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        _ = StoreManager(baseDirectory: tempDir)

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
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.file) == 'table')")
    }

    @Test func fileReadIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.file.read) == 'function')")
    }

    @Test func fileWriteIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.file.write) == 'function')")
    }

    @Test func fileListIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.file.list) == 'function')")
    }

    @Test func fileExistsIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.file.exists) == 'function')")
    }

    @Test func fileWriteAndRead() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
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
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
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
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
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
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
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
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [allowedDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
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
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
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
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.read-missing"
        )
        try state.doString("""
            local content = lingxi.file.read("\(tempDir.path)/nonexistent.txt")
            assert(content == nil, "expected nil, got " .. tostring(content))
        """)
    }

    @Test func fileTailReturnsLastLines() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("tail.txt").path
        try "a\nb\nc\nd\ne\n".write(toFile: filePath, atomically: true, encoding: .utf8)

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.tail"
        )
        try state.doString("""
            local content = lingxi.file.tail("\(filePath)", 2)
            assert(content == "d\\ne", "expected 'd\\\\ne', got '" .. tostring(content) .. "'")
        """)
    }

    @Test func fileTailReturnsAllWhenFileShorter() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("short.txt").path
        try "only\ntwo\n".write(toFile: filePath, atomically: true, encoding: .utf8)

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.tail-short"
        )
        try state.doString("""
            local content = lingxi.file.tail("\(filePath)", 10)
            assert(content == "only\\ntwo", "expected 'only\\\\ntwo', got '" .. tostring(content) .. "'")
        """)
    }

    @Test func fileTailHandlesNoTrailingNewline() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("notrail.txt").path
        try "x\ny\nz".write(toFile: filePath, atomically: true, encoding: .utf8)

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.tail-notrail"
        )
        try state.doString("""
            local content = lingxi.file.tail("\(filePath)", 2)
            assert(content == "y\\nz", "expected 'y\\\\nz', got '" .. tostring(content) .. "'")
        """)
    }

    @Test func fileTailReturnsNilForMissingFile() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.tail-missing"
        )
        try state.doString("""
            local content = lingxi.file.tail("\(tempDir.path)/missing.txt", 3)
            assert(content == nil, "expected nil, got " .. tostring(content))
        """)
    }

    @Test func fileTailDeniedOutsideWhitelist() throws {
        let allowedDir = makeTestTempDir()
        let deniedDir = makeTestTempDir()
        defer {
            try? FileManager.default.removeItem(at: allowedDir)
            try? FileManager.default.removeItem(at: deniedDir)
        }

        let deniedFile = deniedDir.appendingPathComponent("secret.txt").path
        try "a\nb\nc\n".write(toFile: deniedFile, atomically: true, encoding: .utf8)

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [allowedDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.tail-denied"
        )
        try state.doString("""
            local content = lingxi.file.tail("\(deniedFile)", 2)
            assert(content == nil, "expected nil, got " .. tostring(content))
        """)
    }

    @Test func fileTrashDeniedOutsideWhitelist() throws {
        let allowedDir = makeTestTempDir()
        let deniedDir = makeTestTempDir()
        defer {
            try? FileManager.default.removeItem(at: allowedDir)
            try? FileManager.default.removeItem(at: deniedDir)
        }

        let deniedFile = deniedDir.appendingPathComponent("sensitive.txt").path
        try "do not trash".write(toFile: deniedFile, atomically: true, encoding: .utf8)

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [allowedDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.trash-denied"
        )
        try state.doString("""
            local ok = lingxi.file.trash("\(deniedFile)")
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
        // File must not have been moved to user Trash.
        #expect(FileManager.default.fileExists(atPath: deniedFile))
    }

    @Test func fileTailAndTrashDisabledWithoutPermission() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local content = lingxi.file.tail("/tmp/anything.txt", 2)
            assert(content == nil, "expected nil from disabled tail, got " .. tostring(content))
            local ok = lingxi.file.trash("/tmp/anything.txt")
            assert(ok == false, "expected false from disabled trash, got " .. tostring(ok))
        """)
    }

    // MARK: - lingxi.shell

    @Test func shellSubtableExists() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.shell) == 'table')")
    }

    @Test func shellExecIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.shell.exec) == 'function')")
    }

    @Test func shellExecEcho() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local result = lingxi.shell.exec("echo hello")
            assert(type(result) == "table", "expected table, got " .. type(result))
            assert(result.exitCode == 0, "expected exitCode 0, got " .. tostring(result.exitCode))
            assert(result.stdout == "hello\\n", "expected 'hello\\\\n', got '" .. tostring(result.stdout) .. "'")
        """)
    }

    @Test func shellExecDeniedCommand() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local result = lingxi.shell.exec("rm -rf /")
            assert(type(result) == "table", "expected table, got " .. type(result))
            assert(result.exitCode == -1, "expected exitCode -1, got " .. tostring(result.exitCode))
            assert(result.stderr:find("not in shell whitelist") ~= nil, "expected whitelist error, got " .. tostring(result.stderr))
        """)
    }

    @Test func shellExecDisabled() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local result = lingxi.shell.exec("echo hello")
            assert(type(result) == "table", "expected table, got " .. type(result))
            assert(result.exitCode == -1, "expected exitCode -1, got " .. tostring(result.exitCode))
            assert(result.stderr:find("shell permission not granted") ~= nil, "expected permission error, got " .. tostring(result.stderr))
        """)
    }

    @Test func shellExecAbsolutePath() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local result = lingxi.shell.exec("/bin/echo hello")
            assert(type(result) == "table", "expected table, got " .. type(result))
            assert(result.exitCode == 0, "expected exitCode 0, got " .. tostring(result.exitCode))
            assert(result.stdout == "hello\\n", "expected 'hello\\\\n', got '" .. tostring(result.stdout) .. "'")
        """)
    }

    @Test func shellExecMissingArgument() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: ["echo"], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local result = lingxi.shell.exec()
            assert(type(result) == "table", "expected table, got " .. type(result))
            assert(result.exitCode == -1, "expected exitCode -1, got " .. tostring(result.exitCode))
        """)
    }

    // MARK: - lingxi.notify

    @Test func notifySubtableExists() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: true, store: true, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.notify) == 'table')")
    }

    @Test func notifySendIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: true, store: true, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.notify.send) == 'function')")
    }

    @Test func notifySendReturnsBoolean() throws {
        defer { NotificationManager.testingNotifyHandler = nil }
        NotificationManager.testingNotifyHandler = { title, message in
            return title == "Test Title" && message == "Test Message"
        }
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: true, store: true, webview: false, cache: false, db: false))
        try state.doString("""
            local ok = lingxi.notify.send("Test Title", "Test Message")
            assert(type(ok) == "boolean", "expected boolean, got " .. type(ok))
            assert(ok == true, "expected true, got " .. tostring(ok))
        """)
    }

    @Test func notifyDisabledReturnsFalse() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local ok = lingxi.notify.send("Test Title", "Test Message")
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
    }

    @Test func notifyDisabledSubtableStillExists() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.notify) == 'table')")
    }

    @Test func notifySendWithOnlyTitle() throws {
        defer { NotificationManager.testingNotifyHandler = nil }
        NotificationManager.testingNotifyHandler = { title, message in
            return title == "Test Title" && message.isEmpty
        }
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: true, store: true, webview: false, cache: false, db: false))
        try state.doString("""
            local ok = lingxi.notify.send("Test Title")
            assert(type(ok) == "boolean", "expected boolean, got " .. type(ok))
            assert(ok == true, "expected true, got " .. tostring(ok))
        """)
    }

    // MARK: - JSONSerialization round-trip type preservation

    @Test func pushSwiftValueJSONNumberOneIsLuaNumber() throws {
        let state = LuaState()
        state.openLibs()

        // Simulate JSONSerialization result: {"count": 1} -> NSNumber
        let json = "{\"count\": 1}"
        let data = json.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let nsNumber = dict["count"] as! NSNumber

        // Verify it's NOT a CFBoolean
        #expect(CFGetTypeID(nsNumber as CFTypeRef) != CFBooleanGetTypeID(),
                "NSNumber(1) should not be CFBoolean")

        LuaAPI.pushSwiftValue(state.raw, value: nsNumber)

        let luaType = state.type(at: -1)
        #expect(luaType == LUA_TNUMBER,
                "Expected Lua number type (\(LUA_TNUMBER)), got \(luaType)")

        // Verify the value is correct
        let value = state.toNumber(at: -1)
        #expect(value == 1.0, "Expected 1.0, got \(String(describing: value))")
        state.pop()
    }

    @Test func pushSwiftValueJSONBooleanTrueIsLuaBoolean() throws {
        let state = LuaState()
        state.openLibs()

        // Simulate JSONSerialization result: {"enabled": true} -> CFBoolean
        let json = "{\"enabled\": true}"
        let data = json.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let nsNumber = dict["enabled"] as! NSNumber

        // Verify it's a CFBoolean
        #expect(CFGetTypeID(nsNumber as CFTypeRef) == CFBooleanGetTypeID(),
                "JSON true should be CFBoolean")

        LuaAPI.pushSwiftValue(state.raw, value: nsNumber)

        let luaType = state.type(at: -1)
        #expect(luaType == LUA_TBOOLEAN,
                "Expected Lua boolean type (\(LUA_TBOOLEAN)), got \(luaType)")

        // Verify the value is correct
        let value = state.toBool(at: -1)
        #expect(value == true, "Expected true, got \(value)")
        state.pop()
    }

    @Test func pushSwiftValueCFBooleanFalseIsLuaBoolean() throws {
        let state = LuaState()
        state.openLibs()

        let json = "{\"enabled\": false}"
        let data = json.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let nsNumber = dict["enabled"] as! NSNumber

        #expect(CFGetTypeID(nsNumber as CFTypeRef) == CFBooleanGetTypeID(),
                "JSON false should be CFBoolean")

        LuaAPI.pushSwiftValue(state.raw, value: nsNumber)

        let luaType = state.type(at: -1)
        #expect(luaType == LUA_TBOOLEAN,
                "Expected Lua boolean type, got \(luaType)")

        let value = state.toBool(at: -1)
        #expect(value == false, "Expected false, got \(value)")
        state.pop()
    }

    @Test func pushSwiftValueNSNumberZeroIsLuaNumber() throws {
        let state = LuaState()
        state.openLibs()

        // NSNumber 0 should be a number, not boolean
        let nsNumber = NSNumber(value: 0)

        #expect(CFGetTypeID(nsNumber as CFTypeRef) != CFBooleanGetTypeID(),
                "NSNumber(0) should not be CFBoolean")

        LuaAPI.pushSwiftValue(state.raw, value: nsNumber)

        let luaType = state.type(at: -1)
        #expect(luaType == LUA_TNUMBER,
                "Expected Lua number type, got \(luaType)")

        let value = state.toNumber(at: -1)
        #expect(value == 0.0, "Expected 0.0, got \(String(describing: value))")
        state.pop()
    }

    // MARK: - lingxi.alert

    @Test func alertSubtableExists() throws {
        let state = makeState()
        try state.doString("assert(type(lingxi.alert) == 'table')")
    }

    @Test func alertShowIsFunction() throws {
        let state = makeState()
        try state.doString("assert(type(lingxi.alert.show) == 'function')")
    }

    @Test func alertShowReturnsBoolean() throws {
        let state = makeState()
        try state.doString("""
            local ok = lingxi.alert.show("Test Alert")
            assert(ok == true, "expected true, got " .. tostring(ok))
        """)
    }

    @Test func alertShowWithDuration() throws {
        let state = makeState()
        try state.doString("""
            local ok = lingxi.alert.show("Test Alert", 3.0)
            assert(ok == true, "expected true, got " .. tostring(ok))
        """)
    }

    @Test func alertShowRequiresTextArgument() throws {
        let state = makeState()
        try state.doString("""
            local ok = lingxi.alert.show()
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
    }

    // MARK: - lingxi.paste

    @Test func pasteFunctionExists() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.paste) == 'function')")
    }

    @Test func pasteReturnsTrueOnSuccess() throws {
        let pb = NSPasteboard(name: .init("LuaAPITests-paste-\(UUID().uuidString)"))
        defer {
            pb.releaseGlobally()
            LuaAPI.testingPasteboard = nil
        }
        LuaAPI.testingPasteboard = pb

        let state = makeState(permissions: PermissionConfig(network: false, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local ok = lingxi.paste("test-paste-content")
            assert(ok == true, "expected true, got " .. tostring(ok))
        """)
    }

    @Test func pasteReturnsFalseOnNil() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local ok = lingxi.paste(nil)
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
    }

    @Test func pasteDisabledReturnsFalse() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local ok = lingxi.paste("test")
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
    }

    @Test @MainActor func pasteWritesToClipboard() throws {
        // Ensure no panel context is set, so lingxi.paste uses the fallback path
        LuaAPI.panelContext = nil

        let pb = NSPasteboard(name: .init("LuaAPITests-paste-content-\(UUID().uuidString)"))
        defer {
            pb.releaseGlobally()
            LuaAPI.testingPasteboard = nil
        }
        LuaAPI.testingPasteboard = pb

        let state = makeState(permissions: PermissionConfig(network: false, clipboard: true, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            lingxi.paste("clipboard-test-value")
        """)

        // Verify the content was written to clipboard
        let content = pb.string(forType: .string)
        #expect(content == "clipboard-test-value")
    }

    // MARK: - lingxi.json

    @Test func jsonSubtableExists() throws {
        let state = makeState()
        try state.doString("assert(type(lingxi.json) == 'table')")
    }

    @Test func jsonParseIsFunction() throws {
        let state = makeState()
        try state.doString("assert(type(lingxi.json.parse) == 'function')")
    }

    @Test func jsonParseSimpleObject() throws {
        let state = makeState()
        try state.doString("""
            local result = lingxi.json.parse('{"name":"cat","count":3}')
            assert(type(result) == 'table', "expected table, got " .. type(result))
            assert(result.name == 'cat', "expected cat, got " .. tostring(result.name))
            assert(result.count == 3, "expected 3, got " .. tostring(result.count))
        """)
    }

    @Test func jsonParseNestedObject() throws {
        let state = makeState()
        try state.doString("""
            local result = lingxi.json.parse('{"outer":{"inner":"value"}}')
            assert(type(result) == 'table')
            assert(type(result.outer) == 'table')
            assert(result.outer.inner == 'value')
        """)
    }

    @Test func jsonParseArray() throws {
        let state = makeState()
        try state.doString("""
            local result = lingxi.json.parse('[1,2,3]')
            assert(type(result) == 'table')
            assert(result[1] == 1)
            assert(result[2] == 2)
            assert(result[3] == 3)
            assert(#result == 3)
        """)
    }

    @Test func jsonParseArrayOfObjects() throws {
        let state = makeState()
        try state.doString("""
            local result = lingxi.json.parse('[{"name":"a"},{"name":"b"}]')
            assert(type(result) == 'table')
            assert(#result == 2)
            assert(result[1].name == 'a')
            assert(result[2].name == 'b')
        """)
    }

    @Test func jsonParseNullField() throws {
        let state = makeState()
        try state.doString("""
            local result = lingxi.json.parse('{"name":"test","optional":null}')
            assert(type(result) == 'table')
            assert(result.name == 'test')
            assert(result.optional == nil)
        """)
    }

    @Test func jsonParseBoolean() throws {
        let state = makeState()
        try state.doString("""
            local result = lingxi.json.parse('{"active":true,"deleted":false}')
            assert(type(result) == 'table')
            assert(result.active == true)
            assert(result.deleted == false)
        """)
    }

    @Test func jsonParseInvalidJSON() throws {
        let state = makeState()
        try state.doString("""
            local result = lingxi.json.parse('not valid json')
            assert(result == nil, "expected nil for invalid json, got " .. type(result))
        """)
    }

    @Test func jsonParseEmptyString() throws {
        let state = makeState()
        try state.doString("""
            local result = lingxi.json.parse('')
            assert(result == nil)
        """)
    }

    // MARK: - lingxi.fuzzy

    @Test func fuzzySubtableExists() throws {
        let state = makeState()
        try state.doString("assert(type(lingxi.fuzzy) == 'table')")
    }

    @Test func fuzzySearchIsFunction() throws {
        let state = makeState()
        try state.doString("assert(type(lingxi.fuzzy.search) == 'function')")
    }

    @Test func fuzzySearchBasicMatch() throws {
        let state = makeState()
        try state.doString("""
            local items = {
                {name = "cat", group = "animals"},
                {name = "dog", group = "animals"},
                {name = "apple", group = "food"}
            }
            local results = lingxi.fuzzy.search("cat", items, {"name", "group"})
            assert(type(results) == 'table', "expected table, got " .. type(results))
            assert(#results >= 1, "expected at least 1 result, got " .. #results)
            assert(results[1].item.name == 'cat', "expected cat, got " .. tostring(results[1].item.name))
            assert(results[1].score > 0, "expected score > 0, got " .. tostring(results[1].score))
        """)
    }

    @Test func fuzzySearchMultipleFields() throws {
        let state = makeState()
        try state.doString("""
            local items = {
                {name_en = "cat", name_zh = "猫", group = "animals"},
                {name_en = "dog", name_zh = "狗", group = "animals"},
                {name_en = "apple", name_zh = "苹果", group = "food"}
            }
            -- Search by English name across multiple fields
            local results = lingxi.fuzzy.search("cat", items, {"name_en", "name_zh", "group"})
            assert(type(results) == 'table')
            assert(#results >= 1)
            assert(results[1].item.name_en == 'cat')
        """)
    }

    @Test func fuzzySearchEmptyItems() throws {
        let state = makeState()
        try state.doString("""
            local results = lingxi.fuzzy.search("cat", {}, {"name"})
            assert(type(results) == 'table')
            assert(#results == 0)
        """)
    }

    @Test func fuzzySearchEmptyFields() throws {
        let state = makeState()
        try state.doString("""
            local items = {{name = "cat"}}
            local results = lingxi.fuzzy.search("cat", items, {})
            assert(type(results) == 'table')
            assert(#results == 0)
        """)
    }

    @Test func fuzzySearchNoMatch() throws {
        let state = makeState()
        try state.doString("""
            local items = {
                {name = "cat"},
                {name = "dog"}
            }
            local results = lingxi.fuzzy.search("xyz123", items, {"name"})
            assert(type(results) == 'table')
            assert(#results == 0)
        """)
    }

    @Test func fuzzySearchSortedByScore() throws {
        let state = makeState()
        try state.doString("""
            local items = {
                {name = "catfish"},
                {name = "caterpillar"},
                {name = "cat"}
            }
            local results = lingxi.fuzzy.search("cat", items, {"name"})
            assert(#results == 3)
            -- All three items have prefix match (cat*), so scores should be equal and high
            assert(results[1].score == 100, "expected prefix match score 100")
            assert(results[1].score >= results[2].score, "expected descending scores")
            assert(results[2].score >= results[3].score, "expected descending scores")
        """)
    }

    @Test func fuzzySearchPreservesItemStructure() throws {
        let state = makeState()
        try state.doString("""
            local items = {
                {name = "cat", emoji = "🐱", tags = {"animal", "pet"}}
            }
            local results = lingxi.fuzzy.search("cat", items, {"name", "tags"})
            assert(#results == 1)
            assert(results[1].item.emoji == '🐱')
            assert(results[1].item.name == 'cat')
        """)
    }

    // MARK: - lingxi.webview

    @Test func webviewSubtableExistsWithPermission() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: true, cache: false, db: false))
        try state.doString("assert(type(lingxi.webview) == 'table')")
    }

    @Test func webviewSubtableExistsWithoutPermission() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.webview) == 'table')")
    }

    @Test func webviewOpenIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: true, cache: false, db: false))
        try state.doString("assert(type(lingxi.webview.open) == 'function')")
    }

    @Test func webviewCloseIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: true, cache: false, db: false))
        try state.doString("assert(type(lingxi.webview.close) == 'function')")
    }

    @Test func webviewSendIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: true, cache: false, db: false))
        try state.doString("assert(type(lingxi.webview.send) == 'function')")
    }

    @Test func webviewOnMessageIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: true, cache: false, db: false))
        try state.doString("assert(type(lingxi.webview.on_message) == 'function')")
    }

    @Test func webviewOpenReturnsTrueWithPermission() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: true, cache: false, db: false), pluginId: "test.plugin")
        // Create a dummy HTML file in the plugin directory for the test
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let htmlPath = tempDir.appendingPathComponent("test.html").path
        try? "<html><body>Test</body></html>".write(toFile: htmlPath, atomically: true, encoding: .utf8)

        // Resolve relative path via pluginDir
        LuaAPI.registerAll(state: state, permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: true, cache: false, db: false), pluginId: "test.plugin", pluginDir: tempDir.path)

        try state.doString("""
            local ok = lingxi.webview.open("test.html")
            assert(type(ok) == 'boolean', "expected boolean, got " .. type(ok))
            assert(ok == true, "expected true, got " .. tostring(ok))
        """)

        // Clean up
        try? fm.removeItem(at: tempDir)
    }

    @Test func webviewOpenReturnsFalseWithoutPermission() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local ok = lingxi.webview.open("test.html")
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
    }

    @Test func webviewOnMessageRegistersCallback() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: true, cache: false, db: false))
        try state.doString("""
            local received = false
            local ok = lingxi.webview.on_message(function(data)
                received = true
            end)
            assert(type(ok) == 'boolean', "expected boolean, got " .. type(ok))
            assert(ok == true, "expected true, got " .. tostring(ok))
        """)
    }

    @Test func webviewOnMessageReturnsFalseWithoutPermission() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("""
            local ok = lingxi.webview.on_message(function(data) end)
            assert(ok == false, "expected false, got " .. tostring(ok))
        """)
    }

    @Test func webviewSendDoesNothingWithoutWindow() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: true, cache: false, db: false))
        // Should not crash even if no window is open
        try state.doString("""
            lingxi.webview.send('{"action":"test"}')
        """)
    }

    @Test func webviewCloseDoesNothingWithoutWindow() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: true, cache: false, db: false))
        // Should not crash even if no window is open
        try state.doString("""
            lingxi.webview.close()
        """)
    }

    // MARK: - lingxi.cache

    @Test func cacheSubtableExistsWithPermission() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: true, db: false))
        try state.doString("assert(type(lingxi.cache) == 'table')")
    }

    @Test func cacheSubtableExistsWithoutPermission() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.cache) == 'table')")
    }

    @Test func cacheGetPathIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: true, db: false))
        try state.doString("assert(type(lingxi.cache.getPath) == 'function')")
    }

    @Test func cacheGetPathReturnsString() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: true, db: false), pluginId: "test.cache.plugin")
        try state.doString("""
            local path = lingxi.cache.getPath()
            assert(type(path) == 'string', "expected string, got " .. type(path))
            assert(string.find(path, "test.cache.plugin") ~= nil, "expected plugin id in path")
        """)
    }

    @Test func cacheGetPathReturnsNilWithoutPermission() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: false, db: false), pluginId: "test.cache.plugin")
        try state.doString("""
            local path = lingxi.cache.getPath()
            assert(path == nil, "expected nil, got " .. tostring(path))
        """)
    }

    @Test func cacheGetPathReturnsNilWithoutPluginId() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: true, db: false), pluginId: "")
        try state.doString("""
            local path = lingxi.cache.getPath()
            assert(path == nil, "expected nil, got " .. tostring(path))
        """)
    }

    // MARK: - lingxi.file.stat

    @Test func fileStatIsFunction() throws {
        let state = makeState(permissions: PermissionConfig(network: false, clipboard: false, filesystem: ["/tmp"], shell: [], notify: false, store: false, webview: false, cache: false, db: false))
        try state.doString("assert(type(lingxi.file.stat) == 'function')")
    }

    @Test func fileStatReturnsTableForExistingFile() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("stat-test.txt").path
        try "test content".write(toFile: filePath, atomically: true, encoding: .utf8)

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.stat"
        )
        try state.doString("""
            local stat = lingxi.file.stat("\(filePath)")
            assert(type(stat) == 'table', "expected table, got " .. type(stat))
            assert(type(stat.mtime) == 'number', "expected mtime number, got " .. type(stat.mtime))
            assert(type(stat.size) == 'number', "expected size number, got " .. type(stat.size))
            assert(type(stat.isDir) == 'boolean', "expected isDir boolean, got " .. type(stat.isDir))
            assert(stat.isDir == false, "expected isDir false")
            assert(stat.size == 12, "expected size 12, got " .. tostring(stat.size))
        """)
    }

    @Test func fileStatReturnsTableForDirectory() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.stat.dir"
        )
        try state.doString("""
            local stat = lingxi.file.stat("\(tempDir.path)")
            assert(type(stat) == 'table', "expected table, got " .. type(stat))
            assert(stat.isDir == true, "expected isDir true for directory")
        """)
    }

    @Test func fileStatReturnsNilForMissingFile() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [tempDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.stat.missing"
        )
        try state.doString("""
            local stat = lingxi.file.stat("\(tempDir.path)/nonexistent.txt")
            assert(stat == nil, "expected nil for missing file, got " .. type(stat))
        """)
    }

    @Test func fileStatDeniedOutsideWhitelist() throws {
        let allowedDir = makeTestTempDir()
        let deniedDir = makeTestTempDir()
        defer {
            try? FileManager.default.removeItem(at: allowedDir)
            try? FileManager.default.removeItem(at: deniedDir)
        }

        let filePath = deniedDir.appendingPathComponent("test.txt").path
        try "test".write(toFile: filePath, atomically: true, encoding: .utf8)

        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [allowedDir.path], shell: [], notify: false, store: false, webview: false, cache: false, db: false),
            pluginId: "test.file.stat.denied"
        )
        try state.doString("""
            local stat = lingxi.file.stat("\(filePath)")
            assert(stat == nil, "expected nil for denied path, got " .. type(stat))
        """)
    }

    @Test func fileStatWorksInCacheDirectory() throws {
        let state = makeState(
            permissions: PermissionConfig(network: false, clipboard: false, filesystem: [], shell: [], notify: false, store: false, webview: false, cache: true, db: false),
            pluginId: "test.file.stat.cache"
        )

        // Create a file in the cache directory
        let cachePath = RegistryManager.cacheDirectory.appendingPathComponent("test.file.stat.cache").path
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: cachePath), withIntermediateDirectories: true)
        let testFilePath = cachePath + "/test.txt"
        try "cache test".write(toFile: testFilePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: cachePath)) }

        try state.doString("""
            local stat = lingxi.file.stat("\(testFilePath)")
            assert(type(stat) == 'table', "expected table, got " .. type(stat))
            assert(stat.size == 10, "expected size 10, got " .. tostring(stat.size))
        """)
    }
}
