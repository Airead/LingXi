import Foundation

/// Per-plugin key-value store backed by JSON files.
/// Uses NSLock for thread safety so it can be called synchronously from Lua C callbacks.
/// Each plugin gets its own file at `~/.config/LingXi/plugin-data/<plugin-id>.json`.
final class StoreManager: Sendable {
    static let shared = StoreManager()

    private let baseDirectory: URL
    private let lock = NSLock()

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
        lock.lock()
        defer { lock.unlock() }
        let data = loadData(pluginId: pluginId)
        return data[key]
    }

    func set(pluginId: String, key: String, value: Any) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var data = loadData(pluginId: pluginId)
        data[key] = value
        return saveData(pluginId: pluginId, data: data)
    }

    func delete(pluginId: String, key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
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
