import Foundation
import Testing
@testable import LingXi

@MainActor
struct PluginManagerTests {

    // MARK: - loadAll

    @Test func loadAllWithValidPlugin() async throws {
        let dir = try makeTestTempDir(label: "PluginManagerTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "hello", lua: """
            plugin = { name = "hello", prefix = "hi", description = "Hello plugin" }
            function search(query) return {} end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.count == 1)
        #expect(manager.plugins[0].manifest.name == "hello")
        #expect(manager.plugins[0].manifest.prefix == "hi")
        #expect(manager.failures.isEmpty)
    }

    @Test func loadAllWithFailedPlugin() async throws {
        let dir = try makeTestTempDir(label: "PluginManagerTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "broken", lua: "this is not valid lua!!!")

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.isEmpty)
        #expect(manager.failures.count == 1)
        #expect(manager.failures[0].dirName == "broken")
    }

    @Test func loadAllMixedPlugins() async throws {
        let dir = try makeTestTempDir(label: "PluginManagerTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "good", lua: """
            plugin = { name = "good", prefix = "g", description = "works" }
            function search(query) return {} end
        """)
        try writeTestPlugin(in: dir, name: "bad", lua: "syntax error!!!")

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.count == 1)
        #expect(manager.failures.count == 1)
    }

    @Test func loadAllEmptyDirectory() async throws {
        let dir = try makeTestTempDir(label: "PluginManagerTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.isEmpty)
        #expect(manager.failures.isEmpty)
    }

    @Test func loadAllNonexistentDirectory() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.isEmpty)
        #expect(manager.failures.isEmpty)
    }

    // MARK: - reload

    @Test func reloadReplacesPlugins() async throws {
        let dir = try makeTestTempDir(label: "PluginManagerTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "v1", lua: """
            plugin = { name = "v1", prefix = "v", description = "version 1" }
            function search(query) return {} end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.count == 1)
        #expect(manager.plugins[0].manifest.name == "v1")

        // Remove old plugin, add new one
        try FileManager.default.removeItem(at: dir.appendingPathComponent("v1"))
        try writeTestPlugin(in: dir, name: "v2", lua: """
            plugin = { name = "v2", prefix = "v", description = "version 2" }
            function search(query) return {} end
        """)

        await manager.reload()

        #expect(manager.plugins.count == 1)
        #expect(manager.plugins[0].manifest.name == "v2")
        #expect(manager.failures.isEmpty)
    }

    @Test func reloadClearsFailures() async throws {
        let dir = try makeTestTempDir(label: "PluginManagerTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "broken", lua: "bad!!!")

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.failures.count == 1)

        // Fix the plugin
        try "function search(q) return {} end".write(
            to: dir.appendingPathComponent("broken/plugin.lua"),
            atomically: true,
            encoding: .utf8
        )

        await manager.reload()

        #expect(manager.plugins.count == 1)
        #expect(manager.failures.isEmpty)
    }

    @Test func reloadUnregistersOldProviders() async throws {
        let dir = try makeTestTempDir(label: "PluginManagerTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "old", lua: """
            plugin = { name = "old", prefix = "o", description = "old" }
            function search(query) return { { title = "old result", subtitle = "" } } end
        """)

        let router = emptyRouter()
        let manager = PluginManager(router: router, directory: dir)
        await manager.loadAll()

        let results1 = await router.search(rawQuery: "o test")
        #expect(results1.contains { $0.name == "old result" })

        // Remove plugin and reload
        try FileManager.default.removeItem(at: dir.appendingPathComponent("old"))
        await manager.reload()

        let results2 = await router.search(rawQuery: "o test")
        #expect(!results2.contains { $0.name == "old result" })
    }

    // MARK: - summary

    @Test func summaryWithPlugins() async throws {
        let dir = try makeTestTempDir(label: "PluginManagerTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "demo", lua: """
            plugin = { name = "demo", prefix = "d", description = "A demo plugin" }
            function search(query) return {} end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        let summary = manager.summary
        #expect(summary.contains("demo"))
        #expect(summary.contains("[d]"))
    }

    @Test func summaryEmpty() async throws {
        let dir = try makeTestTempDir(label: "PluginManagerTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.summary.contains("No plugins found"))
    }

    // MARK: - Skips non-directory entries

    @Test func skipsRegularFiles() async throws {
        let dir = try makeTestTempDir(label: "PluginManagerTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try "not a plugin".write(
            to: dir.appendingPathComponent("readme.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.isEmpty)
        #expect(manager.failures.isEmpty)
    }
}
