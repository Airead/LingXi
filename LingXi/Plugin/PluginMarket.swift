import Foundation

/// Information about an installed plugin.
nonisolated struct InstalledPluginInfo: Sendable, Equatable {
    let id: String
    let manifest: PluginManifest
    let installInfo: InstallInfo?
    let status: PluginStatus
}

/// Information about an available update.
nonisolated struct UpdateInfo: Sendable, Equatable {
    let id: String
    let currentVersion: String
    let latestVersion: String
}

/// Core plugin market operations: install, uninstall, list, update.
actor PluginMarket {
    private let pluginsDirectory: URL
    private let appVersion: String
    private let registryManager: RegistryManager

    init(
        pluginsDirectory: URL = PluginManager.pluginsDirectory,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
        registryManager: RegistryManager = RegistryManager()
    ) {
        self.pluginsDirectory = pluginsDirectory
        self.appVersion = appVersion
        self.registryManager = registryManager
    }

    // MARK: - Install

    /// Install a plugin from the registry by ID.
    func install(id: String) async throws {
        let registry = try await registryManager.registry()
        guard let plugin = registry.plugins.first(where: { $0.id == id }) else {
            throw PluginMarketError.pluginNotFound(id)
        }
        try await install(from: plugin.sourceURL, id: id)
    }

    /// Install a plugin from a direct plugin.toml URL.
    func install(url: URL) async throws {
        try await install(from: url, id: nil)
    }

    private func install(from sourceURL: URL, id: String?) async throws {
        // 1. Download plugin.toml
        let manifest = try await downloadManifest(from: sourceURL)

        let pluginId = id ?? manifest.id
        guard isValidPluginID(pluginId) else {
            throw PluginMarketError.invalidPluginID(pluginId)
        }

        // 2. Version compatibility check
        if !manifest.minLingXiVersion.isEmpty {
            let comparison = Semver.compare(appVersion, manifest.minLingXiVersion)
            if comparison == .orderedAscending {
                throw PluginMarketError.incompatibleVersion(
                    app: appVersion,
                    required: manifest.minLingXiVersion
                )
            }
        }

        // 3. Create plugin directory
        let pluginDir = pluginsDirectory.appendingPathComponent(sanitizeDirectoryName(pluginId))
        let fm = FileManager.default
        if fm.fileExists(atPath: pluginDir.path) {
            throw PluginMarketError.alreadyInstalled(pluginId)
        }
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        // 4. Download all files
        let baseURL = sourceURL.deletingLastPathComponent()
        do {
            try await downloadFiles(manifest: manifest, baseURL: baseURL, to: pluginDir)

            // 5. Write install.toml
            let installInfo = InstallInfo(
                sourceURL: sourceURL,
                installedVersion: manifest.version,
                installedAt: Date(),
                pinnedRef: ""
            )
            let installTomlURL = pluginDir.appendingPathComponent("install.toml")
            try InstallManifest.write(installInfo, to: installTomlURL)

            DebugLog.log("[PluginMarket] Installed plugin: \(pluginId) v\(manifest.version)")
        } catch {
            // Cleanup on failure
            try? fm.removeItem(at: pluginDir)
            throw error
        }
    }

    // MARK: - Uninstall

    func uninstall(id: String) throws {
        guard isValidPluginID(id) else {
            throw PluginMarketError.invalidPluginID(id)
        }
        let pluginDir = pluginsDirectory.appendingPathComponent(sanitizeDirectoryName(id))
        let fm = FileManager.default
        guard fm.fileExists(atPath: pluginDir.path) else {
            throw PluginMarketError.notInstalled(id)
        }
        try fm.removeItem(at: pluginDir)
        DebugLog.log("[PluginMarket] Uninstalled plugin: \(id)")
    }

    // MARK: - List

    /// List all installed plugins.
    func listInstalled() -> [InstalledPluginInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [InstalledPluginInfo] = []
        for entry in entries where entry.hasDirectoryPath {
            if let info = readInstalledPlugin(at: entry) {
                results.append(info)
            }
        }
        return results.sorted { $0.manifest.id < $1.manifest.id }
    }

    /// List available plugins from registry.
    func listAvailable() async throws -> [RegistryPlugin] {
        let registry = try await registryManager.registry()
        return registry.plugins.sorted { $0.id < $1.id }
    }

    // MARK: - Updates

    func checkUpdates() async throws -> [UpdateInfo] {
        let registry = try await registryManager.registry()
        let installed = listInstalled()

        var updates: [UpdateInfo] = []
        for info in installed {
            guard let installInfo = info.installInfo else { continue } // skip manual
            guard let registryPlugin = registry.plugins.first(where: { $0.id == info.manifest.id }) else { continue }

            if Semver.compare(installInfo.installedVersion, registryPlugin.version) == .orderedAscending {
                updates.append(UpdateInfo(
                    id: info.manifest.id,
                    currentVersion: installInfo.installedVersion,
                    latestVersion: registryPlugin.version
                ))
            }
        }
        return updates
    }

    // MARK: - Private

    private func downloadManifest(from url: URL) async throws -> PluginManifest {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PluginMarketError.downloadFailed(url)
        }
        return try ManifestParser.parseTOML(text)
    }

    private func downloadFiles(manifest: PluginManifest, baseURL: URL, to pluginDir: URL) async throws {
        // Always include plugin.toml itself
        let filesToDownload = ["plugin.toml"] + manifest.files

        for filename in filesToDownload {
            guard !filename.contains("..") else {
                throw PluginMarketError.invalidFilename(filename)
            }
            let fileURL = baseURL.appendingPathComponent(filename)
            let (data, response) = try await URLSession.shared.data(from: fileURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw PluginMarketError.downloadFailed(fileURL)
            }
            let destURL = pluginDir.appendingPathComponent(filename)
            try data.write(to: destURL)
        }
    }

    private func readInstalledPlugin(at dir: URL) -> InstalledPluginInfo? {
        guard let manifest = try? ManifestParser.parseTOMLManifest(from: dir) else {
            return nil
        }

        let installTomlURL = dir.appendingPathComponent("install.toml")
        let installInfo = try? InstallManifest.read(from: installTomlURL)

        let status: PluginStatus = installInfo == nil ? .manuallyPlaced : .installed

        return InstalledPluginInfo(
            id: manifest.id,
            manifest: manifest,
            installInfo: installInfo,
            status: status
        )
    }
}

// MARK: - Helpers

nonisolated func isValidPluginID(_ id: String) -> Bool {
    let forbidden = ["..", "/", "\\", "\0"]
    return !forbidden.contains { id.contains($0) }
}

nonisolated func sanitizeDirectoryName(_ id: String) -> String {
    id.replacingOccurrences(of: "/", with: "-")
}

enum PluginMarketError: Error, Equatable {
    case pluginNotFound(String)
    case invalidPluginID(String)
    case incompatibleVersion(app: String, required: String)
    case alreadyInstalled(String)
    case notInstalled(String)
    case downloadFailed(URL)
    case invalidFilename(String)
}
