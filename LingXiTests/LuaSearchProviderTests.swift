import Foundation
import Testing
@testable import LingXi

struct LuaSearchProviderTests {
    private func makeTempPlugin(luaCode: String) throws -> (provider: LuaSearchProvider, cleanup: () -> Void) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuaSearchProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let scriptPath = tmpDir.appendingPathComponent("plugin.lua")
        try luaCode.write(to: scriptPath, atomically: true, encoding: .utf8)

        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)
        try state.doFile(scriptPath.path)

        let provider = LuaSearchProvider(
            name: "test-plugin",
            pluginDir: tmpDir,
            state: state
        )

        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: tmpDir) }
        return (provider: provider, cleanup: cleanup)
    }

    @Test func basicSearch() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            plugin = { name = "test", prefix = "t", description = "test plugin" }

            function search(query)
                return {
                    { title = "Result " .. query, subtitle = "sub", url = "https://example.com" }
                }
            end
        """)
        defer { cleanup() }

        let results = await provider.search(query: "hello")
        #expect(results.count == 1)
        #expect(results[0].name == "Result hello")
        #expect(results[0].subtitle == "sub")
        #expect(results[0].url?.absoluteString == "https://example.com")
    }

    @Test func emptyQueryReturnsResults() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            function search(query)
                if query == "" then
                    return { { title = "All items", subtitle = "" } }
                end
                return {}
            end
        """)
        defer { cleanup() }

        let results = await provider.search(query: "")
        #expect(results.count == 1)
        #expect(results[0].name == "All items")
    }

    @Test func multipleResults() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            function search(query)
                return {
                    { title = "First", subtitle = "1" },
                    { title = "Second", subtitle = "2" },
                    { title = "Third", subtitle = "3" },
                }
            end
        """)
        defer { cleanup() }

        let results = await provider.search(query: "test")
        #expect(results.count == 3)
        #expect(results[0].name == "First")
        #expect(results[2].name == "Third")
    }

    @Test func customScore() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            function search(query)
                return {
                    { title = "Low", subtitle = "", score = 10 },
                    { title = "High", subtitle = "", score = 90 },
                }
            end
        """)
        defer { cleanup() }

        let results = await provider.search(query: "test")
        #expect(results.count == 2)
        #expect(results[0].score == 10.0)
        #expect(results[1].score == 90.0)
    }

    @Test func noSearchFunction() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            -- No search function defined
            plugin = { name = "empty" }
        """)
        defer { cleanup() }

        let results = await provider.search(query: "test")
        #expect(results.isEmpty)
    }

    @Test func searchFunctionReturnsNonTable() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            function search(query)
                return "not a table"
            end
        """)
        defer { cleanup() }

        let results = await provider.search(query: "test")
        #expect(results.isEmpty)
    }

    @Test func searchFunctionErrorReturnsErrorResult() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            function search(query)
                error("something went wrong")
            end
        """)
        defer { cleanup() }

        let results = await provider.search(query: "test")
        #expect(results.count == 1)
        #expect(results[0].name.contains("error"))
        #expect(results[0].subtitle.contains("something went wrong"))
    }

    @Test func missingTitleSkipsResult() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            function search(query)
                return {
                    { subtitle = "no title" },
                    { title = "has title", subtitle = "ok" },
                }
            end
        """)
        defer { cleanup() }

        let results = await provider.search(query: "test")
        #expect(results.count == 1)
        #expect(results[0].name == "has title")
    }

    @Test func invalidScriptThrows() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuaSearchProviderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptPath = tmpDir.appendingPathComponent("plugin.lua")
        try? "this is not valid lua!!!".write(to: scriptPath, atomically: true, encoding: .utf8)

        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)
        #expect(throws: LuaError.self) {
            try state.doFile(scriptPath.path)
        }
    }

    @Test func defaultScoreIs50() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            function search(query)
                return { { title = "no score", subtitle = "" } }
            end
        """)
        defer { cleanup() }

        let results = await provider.search(query: "test")
        #expect(results.count == 1)
        #expect(results[0].score == 50.0)
    }

    @Test func optionalUrlField() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            function search(query)
                return {
                    { title = "no url", subtitle = "" },
                    { title = "with url", subtitle = "", url = "https://example.com" },
                }
            end
        """)
        defer { cleanup() }

        let results = await provider.search(query: "test")
        #expect(results[0].url == nil)
        #expect(results[1].url?.absoluteString == "https://example.com")
    }

    @Test func actionFunctionRef() async throws {
        let (provider, cleanup) = try makeTempPlugin(luaCode: """
            function search(query)
                local function my_action()
                    -- action body
                end
                return {
                    { title = "Action Item", subtitle = "click me", action = my_action },
                    { title = "No Action", subtitle = "plain item" },
                }
            end
        """)
        defer { cleanup() }

        let results = await provider.search(query: "test")
        #expect(results.count == 2)
        #expect(results[0].action != nil)
        #expect(results[1].action == nil)
    }

    @Test func requireModuleFromPlugin() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuaSearchProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let utilsPath = tmpDir.appendingPathComponent("utils.lua")
        try "return { greet = function(name) return 'Hello, ' .. name end }".write(to: utilsPath, atomically: true, encoding: .utf8)

        let scriptPath = tmpDir.appendingPathComponent("plugin.lua")
        try """
            local utils = require("utils")
            function search(query)
                return {
                    { title = "Greeting", subtitle = utils.greet(query) }
                }
            end
        """.write(to: scriptPath, atomically: true, encoding: .utf8)

        let state = LuaState()
        state.openLibs()
        LuaSandbox.apply(to: state)
        LuaSandbox.setupPackagePath(to: state, pluginDir: tmpDir.path)
        try state.doFile(scriptPath.path)

        let provider = LuaSearchProvider(
            name: "test-plugin",
            pluginDir: tmpDir,
            state: state
        )

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let results = await provider.search(query: "World")
        #expect(results.count == 1)
        #expect(results[0].name == "Greeting")
        #expect(results[0].subtitle == "Hello, World")
    }
}
