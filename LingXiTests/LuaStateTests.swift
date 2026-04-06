import Foundation
import Testing
@testable import LingXi

struct LuaStateTests {
    @Test func initAndDeinit() {
        let state = LuaState()
        #expect(state.top == 0)
    }

    @Test func pushAndReadString() {
        let state = LuaState()
        state.push("hello")
        #expect(state.top == 1)
        #expect(state.toString(at: -1) == "hello")
        state.pop()
        #expect(state.top == 0)
    }

    @Test func pushAndReadNumber() {
        let state = LuaState()
        state.push(3.14)
        #expect(state.toNumber(at: -1) == 3.14)
        state.pop()
    }

    @Test func pushAndReadInt() {
        let state = LuaState()
        state.push(42)
        #expect(state.toInt(at: -1) == 42)
        state.pop()
    }

    @Test func pushAndReadBool() {
        let state = LuaState()
        state.push(true)
        #expect(state.toBool(at: -1) == true)
        state.push(false)
        #expect(state.toBool(at: -1) == false)
        state.pop(2)
    }

    @Test func pushNil() {
        let state = LuaState()
        state.pushNil()
        #expect(state.isNil(at: -1))
        state.pop()
    }

    @Test func doStringSimple() throws {
        let state = LuaState()
        state.openLibs()
        try state.doString("x = 1 + 2")
        state.getGlobal("x")
        #expect(state.toInt(at: -1) == 3)
        state.pop()
    }

    @Test func doStringWithError() {
        let state = LuaState()
        state.openLibs()
        #expect(throws: LuaError.self) {
            try state.doString("this is not valid lua!!!")
        }
    }

    @Test func doStringRuntimeError() {
        let state = LuaState()
        state.openLibs()
        #expect(throws: LuaError.self) {
            try state.doString("error('boom')")
        }
    }

    @Test func tableOperations() throws {
        let state = LuaState()
        state.openLibs()
        try state.doString("""
            t = { name = "test", value = 42.5 }
        """)
        state.getGlobal("t")
        #expect(state.isTable(at: -1))
        #expect(state.stringField("name", at: -1) == "test")
        #expect(state.numberField("value", at: -1) == 42.5)
        state.pop()
    }

    @Test func iterateArray() throws {
        let state = LuaState()
        state.openLibs()
        try state.doString("""
            arr = {"a", "b", "c"}
        """)
        state.getGlobal("arr")

        var collected: [String] = []
        state.iterateArray(at: -1) {
            if let s = state.toString(at: -1) {
                collected.append(s)
            }
        }
        state.pop()

        #expect(collected == ["a", "b", "c"])
    }

    @Test func iterateEmptyArray() throws {
        let state = LuaState()
        state.openLibs()
        try state.doString("arr = {}")
        state.getGlobal("arr")

        var count = 0
        state.iterateArray(at: -1) {
            count += 1
        }
        state.pop()

        #expect(count == 0)
    }

    @Test func doFileNotFound() {
        let state = LuaState()
        #expect(throws: LuaError.self) {
            try state.doFile("/nonexistent/path/to/file.lua")
        }
    }

    @Test func doFileValid() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuaStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptPath = tmpDir.appendingPathComponent("test.lua")
        try "result = 10 + 20".write(to: scriptPath, atomically: true, encoding: .utf8)

        let state = LuaState()
        state.openLibs()
        try state.doFile(scriptPath.path)
        state.getGlobal("result")
        #expect(state.toInt(at: -1) == 30)
        state.pop()
    }

    @Test func globalManipulation() throws {
        let state = LuaState()
        state.openLibs()
        try state.doString("x = 'hello'")

        state.getGlobal("x")
        #expect(state.toString(at: -1) == "hello")
        state.pop()

        state.removeGlobal("x")
        state.getGlobal("x")
        #expect(state.isNil(at: -1))
        state.pop()
    }

    @Test func removeGlobalField() throws {
        let state = LuaState()
        state.openLibs()
        try state.doString("t = { a = 1, b = 2 }")

        state.removeGlobalField(table: "t", field: "a")

        state.getGlobal("t")
        #expect(state.numberField("a", at: -1) == nil)
        #expect(state.numberField("b", at: -1) == 2.0)
        state.pop()
    }

    @Test func typeChecking() throws {
        let state = LuaState()
        state.openLibs()
        // toString on a number should return nil (type mismatch)
        state.push(42)
        #expect(state.toString(at: -1) == nil)
        // toNumber on a string should return nil
        state.push("hello")
        #expect(state.toNumber(at: -1) == nil)
        state.pop(2)
    }
}
