import Foundation

/// Actor-isolated per-plugin key-value store backed by JSON files.
/// Each plugin gets its own file at `~/.config/LingXi/plugin-data/<plugin-id>.json`.
actor StoreManager {
    static let shared = StoreManager()

    private let baseDirectory: URL

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            self.baseDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/LingXi/plugin-data", isDirectory: true)
        }
    }

    // MARK: - Public API

    func get(pluginId: String, key: String) -> Any? {
        let data = loadData(pluginId: pluginId)
        return data[key]
    }

    func set(pluginId: String, key: String, value: Any) -> Bool {
        var data = loadData(pluginId: pluginId)
        data[key] = value
        return saveData(pluginId: pluginId, data: data)
    }

    func delete(pluginId: String, key: String) -> Bool {
        var data = loadData(pluginId: pluginId)
        data.removeValue(forKey: key)
        return saveData(pluginId: pluginId, data: data)
    }

    // MARK: - File I/O

    private func fileURL(pluginId: String) -> URL {
        baseDirectory.appendingPathComponent("\(pluginId).json")
    }

    private func loadData(pluginId: String) -> [String: Any] {
        let url = fileURL(pluginId: pluginId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func saveData(pluginId: String, data: [String: Any]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
            try jsonData.write(to: fileURL(pluginId: pluginId), options: .atomic)
            return true
        } catch {
            DebugLog.log("[StoreManager] Failed to save data for plugin \(pluginId): \(error)")
            return false
        }
    }
}

// MARK: - Synchronous wrappers for Lua C callbacks

extension StoreManager {
    /// Synchronous wrapper for `get`. Blocks until the actor method completes.
    nonisolated func syncGet(pluginId: String, key: String) -> Any? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Any?
        Task {
            result = await get(pluginId: pluginId, key: key)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Synchronous wrapper for `set`. Blocks until the actor method completes.
    nonisolated func syncSet(pluginId: String, key: String, value: Any) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        Task {
            result = await set(pluginId: pluginId, key: key, value: value)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Synchronous wrapper for `delete`. Blocks until the actor method completes.
    nonisolated func syncDelete(pluginId: String, key: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        Task {
            result = await delete(pluginId: pluginId, key: key)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
