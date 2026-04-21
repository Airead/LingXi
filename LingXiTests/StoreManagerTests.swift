import Foundation
import Testing
@testable import LingXi

struct StoreManagerTests {
    private func makeStore() -> StoreManager {
        let tempDir = makeTestTempDir()
        return StoreManager(baseDirectory: tempDir)
    }

    // MARK: - Basic operations

    @Test func getReturnsNilForMissingKey() async {
        let store = makeStore()
        let value = await store.get(pluginId: "test", key: "missing")
        #expect(value == nil)
    }

    @Test func setAndGetString() async {
        let store = makeStore()
        let ok = await store.set(pluginId: "test", key: "name", value: "hello")
        #expect(ok == true)
        let value = await store.get(pluginId: "test", key: "name")
        #expect(value as? String == "hello")
    }

    @Test func setAndGetNumber() async {
        let store = makeStore()
        let ok = await store.set(pluginId: "test", key: "count", value: 42)
        #expect(ok == true)
        let value = await store.get(pluginId: "test", key: "count")
        #expect(value as? Int == 42)
    }

    @Test func setAndGetBoolean() async {
        let store = makeStore()
        let ok = await store.set(pluginId: "test", key: "enabled", value: true)
        #expect(ok == true)
        let value = await store.get(pluginId: "test", key: "enabled")
        #expect(value as? Bool == true)
    }

    @Test func setAndGetDictionary() async {
        let store = makeStore()
        let data: [String: Any] = ["name": "test", "value": 123]
        let ok = await store.set(pluginId: "test", key: "data", value: data)
        #expect(ok == true)
        let value = await store.get(pluginId: "test", key: "data")
        let dict = value as? [String: Any]
        #expect(dict != nil)
        #expect(dict?["name"] as? String == "test")
        #expect(dict?["value"] as? Int == 123)
    }

    @Test func setAndGetArray() async {
        let store = makeStore()
        let list: [Any] = ["one", "two", "three"]
        let ok = await store.set(pluginId: "test", key: "list", value: list)
        #expect(ok == true)
        let value = await store.get(pluginId: "test", key: "list")
        let arr = value as? [Any]
        #expect(arr != nil)
        #expect(arr?.count == 3)
        #expect(arr?[0] as? String == "one")
    }

    @Test func deleteRemovesKey() async {
        let store = makeStore()
        await store.set(pluginId: "test", key: "temp", value: "value")
        let ok = await store.delete(pluginId: "test", key: "temp")
        #expect(ok == true)
        let value = await store.get(pluginId: "test", key: "temp")
        #expect(value == nil)
    }

    @Test func deleteReturnsTrueForMissingKey() async {
        let store = makeStore()
        let ok = await store.delete(pluginId: "test", key: "missing")
        #expect(ok == true)
    }

    // MARK: - Plugin isolation

    @Test func pluginsAreIsolated() async {
        let store = makeStore()
        await store.set(pluginId: "plugin.a", key: "shared", value: "a-value")
        await store.set(pluginId: "plugin.b", key: "shared", value: "b-value")

        let valueA = await store.get(pluginId: "plugin.a", key: "shared")
        let valueB = await store.get(pluginId: "plugin.b", key: "shared")

        #expect(valueA as? String == "a-value")
        #expect(valueB as? String == "b-value")
    }

    // MARK: - Persistence

    @Test func dataPersistsToDisk() async throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store1 = StoreManager(baseDirectory: tempDir)
        await store1.set(pluginId: "persist-test", key: "counter", value: 7)

        // Create a new manager instance pointing to the same directory
        let store2 = StoreManager(baseDirectory: tempDir)
        let value = await store2.get(pluginId: "persist-test", key: "counter")

        #expect(value as? Int == 7)
    }

    @Test func createsJsonFile() async throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = StoreManager(baseDirectory: tempDir)
        await store.set(pluginId: "file-test", key: "name", value: "hello")

        let fileURL = tempDir.appendingPathComponent("file-test.json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["name"] as? String == "hello")
    }

    // MARK: - Synchronous wrappers

    @Test func syncGetReturnsValue() {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = StoreManager(baseDirectory: tempDir)
        _ = store.syncSet(pluginId: "sync", key: "key", value: "sync-value")
        let value = store.syncGet(pluginId: "sync", key: "key")
        #expect(value as? String == "sync-value")
    }

    @Test func syncSetReturnsTrue() {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = StoreManager(baseDirectory: tempDir)
        let ok = store.syncSet(pluginId: "sync", key: "key", value: "value")
        #expect(ok == true)
    }

    @Test func syncDeleteRemovesKey() {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = StoreManager(baseDirectory: tempDir)
        _ = store.syncSet(pluginId: "sync", key: "temp", value: "value")
        let ok = store.syncDelete(pluginId: "sync", key: "temp")
        #expect(ok == true)
        let value = store.syncGet(pluginId: "sync", key: "temp")
        #expect(value == nil)
    }
}
