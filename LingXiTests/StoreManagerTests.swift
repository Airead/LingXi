import Foundation
import Testing
@testable import LingXi

struct StoreManagerTests {
    private func makeStore() -> StoreManager {
        let tempDir = makeTestTempDir()
        return StoreManager(baseDirectory: tempDir)
    }

    // MARK: - Basic operations

    @Test func getReturnsNilForMissingKey() {
        let store = makeStore()
        let value = store.get(pluginId: "test", key: "missing")
        #expect(value == nil)
    }

    @Test func setAndGetString() {
        let store = makeStore()
        let ok = store.set(pluginId: "test", key: "name", value: "hello")
        #expect(ok == true)
        let value = store.get(pluginId: "test", key: "name")
        #expect(value as? String == "hello")
    }

    @Test func setAndGetNumber() {
        let store = makeStore()
        let ok = store.set(pluginId: "test", key: "count", value: 42)
        #expect(ok == true)
        let value = store.get(pluginId: "test", key: "count")
        #expect(value as? Int == 42)
    }

    @Test func setAndGetBoolean() {
        let store = makeStore()
        let ok = store.set(pluginId: "test", key: "enabled", value: true)
        #expect(ok == true)
        let value = store.get(pluginId: "test", key: "enabled")
        #expect(value as? Bool == true)
    }

    @Test func setAndGetDictionary() {
        let store = makeStore()
        let data: [String: Any] = ["name": "test", "value": 123]
        let ok = store.set(pluginId: "test", key: "data", value: data)
        #expect(ok == true)
        let value = store.get(pluginId: "test", key: "data")
        let dict = value as? [String: Any]
        #expect(dict != nil)
        #expect(dict?["name"] as? String == "test")
        #expect(dict?["value"] as? Int == 123)
    }

    @Test func setAndGetArray() {
        let store = makeStore()
        let list: [Any] = ["one", "two", "three"]
        let ok = store.set(pluginId: "test", key: "list", value: list)
        #expect(ok == true)
        let value = store.get(pluginId: "test", key: "list")
        let arr = value as? [Any]
        #expect(arr != nil)
        #expect(arr?.count == 3)
        #expect(arr?[0] as? String == "one")
    }

    @Test func deleteRemovesKey() {
        let store = makeStore()
        store.set(pluginId: "test", key: "temp", value: "value")
        let ok = store.delete(pluginId: "test", key: "temp")
        #expect(ok == true)
        let value = store.get(pluginId: "test", key: "temp")
        #expect(value == nil)
    }

    @Test func deleteReturnsTrueForMissingKey() {
        let store = makeStore()
        let ok = store.delete(pluginId: "test", key: "missing")
        #expect(ok == true)
    }

    // MARK: - Plugin isolation

    @Test func pluginsAreIsolated() {
        let store = makeStore()
        store.set(pluginId: "plugin.a", key: "shared", value: "a-value")
        store.set(pluginId: "plugin.b", key: "shared", value: "b-value")

        let valueA = store.get(pluginId: "plugin.a", key: "shared")
        let valueB = store.get(pluginId: "plugin.b", key: "shared")

        #expect(valueA as? String == "a-value")
        #expect(valueB as? String == "b-value")
    }

    // MARK: - Persistence

    @Test func dataPersistsToDisk() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store1 = StoreManager(baseDirectory: tempDir)
        store1.set(pluginId: "persist-test", key: "counter", value: 7)

        // Create a new manager instance pointing to the same directory
        let store2 = StoreManager(baseDirectory: tempDir)
        let value = store2.get(pluginId: "persist-test", key: "counter")

        #expect(value as? Int == 7)
    }

    @Test func createsJsonFile() throws {
        let tempDir = makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = StoreManager(baseDirectory: tempDir)
        store.set(pluginId: "file-test", key: "name", value: "hello")

        let fileURL = tempDir.appendingPathComponent("file-test.json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["name"] as? String == "hello")
    }

    // MARK: - Thread safety

    @Test func concurrentAccessIsSafe() {
        let store = makeStore()
        let iterations = 100

        DispatchQueue.concurrentPerform(iterations: 4) { threadIndex in
            for i in 0..<iterations {
                let key = "thread_\(threadIndex)_\(i)"
                store.set(pluginId: "concurrent", key: key, value: i)
                let value = store.get(pluginId: "concurrent", key: key)
                #expect(value as? Int == i)
            }
        }
    }
}
