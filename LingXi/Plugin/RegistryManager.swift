import Foundation

/// Manages the official plugin registry: fetching, caching, and refreshing.
actor RegistryManager {
    nonisolated static let builtinRegistryURL = URL(
        string: "https://raw.githubusercontent.com/Airead/LingXi/main/plugins/registry.toml"
    )!

    nonisolated static let cacheDirectory: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/LingXi", isDirectory: true)

    nonisolated static let cacheFile: URL = cacheDirectory.appendingPathComponent("registry.toml")

    /// Time-to-live for cached registry in seconds (24 hours).
    nonisolated static let cacheTTL: TimeInterval = 24 * 60 * 60

    private let registryURL: URL
    private let cacheURL: URL
    private let ttl: TimeInterval

    init(
        registryURL: URL = builtinRegistryURL,
        cacheURL: URL = cacheFile,
        ttl: TimeInterval = cacheTTL
    ) {
        self.registryURL = registryURL
        self.cacheURL = cacheURL
        self.ttl = ttl
    }

    /// Fetch the registry from the network.
    func fetchRegistry() async -> String? {
        do {
            let (data, _) = try await URLSession.shared.data(from: registryURL)
            return String(data: data, encoding: .utf8)
        } catch {
            DebugLog.log("[RegistryManager] Failed to fetch registry: \(error)")
            return nil
        }
    }

    /// Read the cached registry if it exists and is not expired.
    func cachedRegistry() throws -> PluginRegistry? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        let attrs = try fm.attributesOfItem(atPath: cacheURL.path)
        if let modDate = attrs[.modificationDate] as? Date {
            let age = Date().timeIntervalSince(modDate)
            if age > ttl {
                DebugLog.log("[RegistryManager] Cache expired (age: \(age)s)")
                return nil
            }
        }

        let text = try String(contentsOf: cacheURL, encoding: .utf8)
        return try RegistryParser.parse(text)
    }

    /// Download and cache the registry. Throws on failure.
    func refreshRegistry() async throws -> PluginRegistry {
        guard let text = await fetchRegistry() else {
            // Fallback to cache
            if let cached = try? cachedRegistry() {
                DebugLog.log("[RegistryManager] Using cached registry (network unavailable)")
                return cached
            }
            throw RegistryError.networkUnavailable
        }

        let registry = try RegistryParser.parse(text)
        try writeCache(text)
        return registry
    }

    /// Get registry (cached if fresh, otherwise refresh).
    func registry() async throws -> PluginRegistry {
        if let cached = try? cachedRegistry() {
            return cached
        }
        return try await refreshRegistry()
    }

    // MARK: - Private

    private func writeCache(_ text: String) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: cacheURL, atomically: true, encoding: .utf8)
    }
}

enum RegistryError: Error {
    case networkUnavailable
}
