import Foundation
import Testing
@testable import LingXi

@MainActor
struct PluginEventTests {

    // MARK: - dispatchEvent on LuaSearchProvider

    @Test func dispatchEventCallsSpecificLuaFunction() async throws {
        let dir = makeTestTempDir(label: "PluginEventTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "event-test", lua: """
            plugin = { name = "event-test", prefix = "ev" }
            last_event_text = ""
            last_event_app = ""
            function on_clipboard_change(item)
                last_event_text = item.text or ""
                last_event_app = item.source_app or ""
            end
            function search(query)
                return {
                    { title = last_event_text, subtitle = last_event_app }
                }
            end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.count == 1)
        let provider = manager.plugins[0].provider

        // Dispatch event using new raw value name
        await provider.dispatchEvent(
            name: "clipboard_change",
            data: ["text": "hello from clipboard", "source_app": "Safari"]
        )

        // Verify by searching (which reads the stored event data)
        let results = await provider.search(query: "check")
        #expect(results.count == 1)
        #expect(results[0].name == "hello from clipboard")
        #expect(results[0].subtitle == "Safari")
    }

    @Test func dispatchEventCallsGenericOnEvent() async throws {
        let dir = makeTestTempDir(label: "PluginEventTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "generic-event", lua: """
            plugin = { name = "generic-event", prefix = "ge" }
            last_event = ""
            last_data = ""
            function on_event(event, data)
                last_event = event
                last_data = data.query or ""
            end
            function search(query)
                return {
                    { title = last_event, subtitle = last_data }
                }
            end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.count == 1)
        let provider = manager.plugins[0].provider

        // Dispatch event — should be caught by on_event
        await provider.dispatchEvent(
            name: "search_activate",
            data: ["query": "hello world"]
        )

        let results = await provider.search(query: "check")
        #expect(results.count == 1)
        #expect(results[0].name == "search_activate")
        #expect(results[0].subtitle == "hello world")
    }

    @Test func dispatchEventIgnoresMissingHandler() async throws {
        let dir = makeTestTempDir(label: "PluginEventTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "no-handler", lua: """
            plugin = { name = "no-handler", prefix = "nh" }
            function search(query) return {} end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        let provider = manager.plugins[0].provider

        // Should not crash or error when handler is missing
        await provider.dispatchEvent(
            name: "clipboard_change",
            data: ["text": "test"]
        )

        let results = await provider.search(query: "test")
        #expect(results.isEmpty)
    }

    @Test func dispatchEventHandlesLuaError() async throws {
        let dir = makeTestTempDir(label: "PluginEventTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "error-handler", lua: """
            plugin = { name = "error-handler", prefix = "eh" }
            function on_clipboard_change(item)
                error("intentional error")
            end
            function search(query) return {} end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        let provider = manager.plugins[0].provider

        // Should not crash; error is logged
        await provider.dispatchEvent(
            name: "clipboard_change",
            data: ["text": "trigger error"]
        )

        // Plugin should still work after error
        let results = await provider.search(query: "test")
        #expect(results.isEmpty)
    }

    // MARK: - dispatchEvent on PluginManager (broadcasts to all)

    @Test func managerDispatchesToAllPlugins() async throws {
        let dir = makeTestTempDir(label: "PluginEventTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "plugin-a", lua: """
            plugin = { name = "plugin-a", prefix = "pa" }
            received = ""
            function on_search_activate(data)
                received = data.prefix or "none"
            end
            function search(query)
                return { { title = received } }
            end
        """)

        try writeTestPlugin(in: dir, name: "plugin-b", lua: """
            plugin = { name = "plugin-b", prefix = "pb" }
            received = ""
            function on_search_activate(data)
                received = data.prefix or "none"
            end
            function search(query)
                return { { title = received } }
            end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.count == 2)

        // Dispatch to all
        await manager.dispatchEvent(
            name: "search_activate",
            data: ["prefix": "file"]
        )

        // Both plugins should have received the event
        for plugin in manager.plugins {
            let results = await plugin.provider.search(query: "check")
            #expect(results.count == 1)
            #expect(results[0].name == "file")
        }
    }

    // MARK: - ClipboardStore onChange callback

    @Test func clipboardStoreFiresOnChange() async throws {
        let tmpDir = makeTestTempDir(label: "PluginEventClipboard")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        assertTestImageDirectory(tmpDir)

        let db = await DatabaseManager()
        let store = ClipboardStore(database: db, capacity: 10, imageDirectory: tmpDir)

        nonisolated(unsafe) var receivedItem: ClipboardItem?

        await store.setOnChange { item in
            receivedItem = item
        }

        await store.addTextEntry("test clipboard change")

        #expect(receivedItem != nil)
        #expect(receivedItem?.textContent == "test clipboard change")
        #expect(receivedItem?.contentType == .text)
    }

    // MARK: - LuaSearchProvider.executeFunction

    @Test func executeFunctionCallsLuaCode() async throws {
        let dir = makeTestTempDir(label: "PluginEventTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "exec-fn", lua: """
            plugin = { name = "exec-fn", prefix = "ef" }
            result_value = ""
            function my_action(args)
                result_value = "got:" .. args
            end
            function search(query)
                return { { title = result_value } }
            end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        let provider = manager.plugins[0].provider
        await provider.executeFunction(name: "my_action", args: "hello")

        let results = await provider.search(query: "check")
        #expect(results.count == 1)
        #expect(results[0].name == "got:hello")
    }

    @Test func executeFunctionHandlesMissingFunction() async throws {
        let dir = makeTestTempDir(label: "PluginEventTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "missing-fn", lua: """
            plugin = { name = "missing-fn", prefix = "mf" }
            function search(query) return {} end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        let provider = manager.plugins[0].provider

        // Should not crash
        await provider.executeFunction(name: "nonexistent_function", args: "test")

        let results = await provider.search(query: "test")
        #expect(results.isEmpty)
    }

    // MARK: - PluginManager.reload triggers plugin_reload

    @Test func reloadTriggersPluginReloadEvent() async throws {
        let dir = makeTestTempDir(label: "PluginEventTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTestPlugin(in: dir, name: "reload-test", lua: """
            plugin = { name = "reload-test", prefix = "rt" }
            reload_received = false
            function on_plugin_reload(data)
                reload_received = true
            end
            function search(query)
                local title = reload_received and "reloaded" or "not-reloaded"
                return { { title = title } }
            end
        """)

        let manager = PluginManager(router: emptyRouter(), directory: dir)
        await manager.loadAll()

        #expect(manager.plugins.count == 1)

        // Before reload, plugin should not have received the event
        let resultsBefore = await manager.plugins[0].provider.search(query: "check")
        #expect(resultsBefore.count == 1)
        #expect(resultsBefore[0].name == "not-reloaded")

        // Reload triggers plugin_reload event
        await manager.reload()

        // After reload, the plugin should have been reloaded and received the event
        // Note: because reload() unloads all plugins before re-loading them,
        // the old plugin instance is gone. We need to check the new instance.
        #expect(manager.plugins.count == 1)
        let resultsAfter = await manager.plugins[0].provider.search(query: "check")
        #expect(resultsAfter.count == 1)
        #expect(resultsAfter[0].name == "reloaded")
    }
}
