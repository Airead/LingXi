import Foundation
import Testing
@testable import LingXi

struct LuaSandboxTests {
    private func makeSandboxedState() -> LuaState {
        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)
        return state
    }

    @Test(arguments: [
        "os.execute", "os.exit", "os.remove", "os.rename", "os.tmpname",
        "os.setlocale", "os.getenv",
        "io.open", "io.popen", "io.input", "io.output", "io.tmpfile",
        "io.close", "io.read", "io.write", "io.lines",
        "package.loadlib",
        "dofile", "loadfile", "load", "debug",
    ])
    func dangerousGlobalRemoved(_ name: String) throws {
        let state = makeSandboxedState()
        try state.doString("result = (\(name) == nil)")
        state.getGlobal("result")
        #expect(state.toBool(at: -1) == true, "\(name) should be removed by sandbox")
        state.pop()
    }

    @Test func safeOsFunctionsPreserved() throws {
        let state = makeSandboxedState()
        // os.clock and os.time should still work
        try state.doString("result = type(os.clock)")
        state.getGlobal("result")
        #expect(state.toString(at: -1) == "function")
        state.pop()

        try state.doString("result = type(os.time)")
        state.getGlobal("result")
        #expect(state.toString(at: -1) == "function")
        state.pop()
    }

    @Test func safeGlobalsPreserved() throws {
        let state = makeSandboxedState()
        // Standard safe functions should remain
        for fn in ["print", "tostring", "tonumber", "type", "pairs", "ipairs", "pcall", "select"] {
            try state.doString("result = type(\(fn))")
            state.getGlobal("result")
            #expect(state.toString(at: -1) == "function", "Expected \(fn) to be preserved")
            state.pop()
        }
    }

    @Test func stringAndTableLibsPreserved() throws {
        let state = makeSandboxedState()
        try state.doString("result = type(string.format)")
        state.getGlobal("result")
        #expect(state.toString(at: -1) == "function")
        state.pop()

        try state.doString("result = type(table.insert)")
        state.getGlobal("result")
        #expect(state.toString(at: -1) == "function")
        state.pop()
    }

    @Test func mathLibPreserved() throws {
        let state = makeSandboxedState()
        try state.doString("result = math.abs(-5)")
        state.getGlobal("result")
        #expect(state.toInt(at: -1) == 5)
        state.pop()
    }

    @Test func requireFunctionPreserved() throws {
        let state = makeSandboxedState()
        try state.doString("result = type(require)")
        state.getGlobal("result")
        #expect(state.toString(at: -1) == "function")
        state.pop()
    }

    @Test func packagePathSetup() throws {
        let state = makeSandboxedState()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuaSandboxTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        LuaSandbox.setupPackagePath(to: state, pluginDir: tempDir.path)

        try state.doString("result = package.path")
        state.getGlobal("result")
        let path = state.toString(at: -1) ?? ""
        #expect(path.hasPrefix(tempDir.path), "package.path should start with plugin directory")
        #expect(path.contains("/?.lua"), "package.path should contain /?.lua pattern")
        state.pop()
    }
}
