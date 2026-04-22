import Foundation
import Testing
@testable import LingXi

// MARK: - RegistryParser Tests

struct RegistryParserTests {
    @Test func parseRegistry() throws {
        let toml = """
        name = "Test Registry"
        url = "https://github.com/test/test"

        [[plugins]]
        id = "test.plugin"
        name = "Test Plugin"
        version = "1.0.0"
        source = "https://example.com/test/plugin.toml"
        min_lingxi_version = "0.1.0"
        """

        let registry = try RegistryParser.parse(toml)
        #expect(registry.name == "Test Registry")
        #expect(registry.url == "https://github.com/test/test")
        #expect(registry.plugins.count == 1)
        #expect(registry.plugins[0].id == "test.plugin")
        #expect(registry.plugins[0].name == "Test Plugin")
        #expect(registry.plugins[0].version == "1.0.0")
        #expect(registry.plugins[0].minLingXiVersion == "0.1.0")
    }

    @Test func parseRegistryMissingName() {
        let toml = """
        url = "https://github.com/test/test"
        """

        #expect(throws: RegistryParser.Error.self) {
            try RegistryParser.parse(toml)
        }
    }

    @Test func parseRegistryEmptyPlugins() throws {
        let toml = """
        name = "Empty Registry"
        url = "https://github.com/test/test"
        """

        let registry = try RegistryParser.parse(toml)
        #expect(registry.plugins.isEmpty)
    }
}

// MARK: - Semver Tests

struct SemverTests {
    @Test func compareEqual() {
        #expect(Semver.compare("1.0.0", "1.0.0") == .orderedSame)
    }

    @Test func compareAscending() {
        #expect(Semver.compare("1.0.0", "1.0.1") == .orderedAscending)
        #expect(Semver.compare("1.0.0", "1.1.0") == .orderedAscending)
        #expect(Semver.compare("1.0.0", "2.0.0") == .orderedAscending)
    }

    @Test func compareDescending() {
        #expect(Semver.compare("1.0.1", "1.0.0") == .orderedDescending)
        #expect(Semver.compare("1.1.0", "1.0.0") == .orderedDescending)
        #expect(Semver.compare("2.0.0", "1.0.0") == .orderedDescending)
    }

    @Test func compareDifferentLength() {
        #expect(Semver.compare("1.0", "1.0.0") == .orderedSame)
        #expect(Semver.compare("1.0", "1.0.1") == .orderedAscending)
    }
}

// MARK: - RegistryManager Tests

struct RegistryManagerTests {
    @Test func cachedRegistryReturnsNilWhenMissing() async throws {
        let tempDir = makeTestTempDir(label: "RegistryManagerTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cacheFile = tempDir.appendingPathComponent("registry.toml")
        let manager = RegistryManager(
            registryURL: URL(string: "https://example.com/registry.toml")!,
            cacheURL: cacheFile
        )

        let cached = try await manager.cachedRegistry()
        #expect(cached == nil)
    }

    @Test func cachedRegistryReadsValidCache() async throws {
        let tempDir = makeTestTempDir(label: "RegistryManagerTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let toml = """
        name = "Cached Registry"
        url = "https://github.com/test/test"

        [[plugins]]
        id = "cached.plugin"
        name = "Cached Plugin"
        version = "1.0.0"
        source = "https://example.com/cached/plugin.toml"
        """

        let cacheFile = tempDir.appendingPathComponent("registry.toml")
        try toml.write(to: cacheFile, atomically: true, encoding: .utf8)

        let manager = RegistryManager(
            registryURL: URL(string: "https://example.com/registry.toml")!,
            cacheURL: cacheFile
        )

        let cached = try await manager.cachedRegistry()
        #expect(cached != nil)
        #expect(cached?.name == "Cached Registry")
        #expect(cached?.plugins.count == 1)
        #expect(cached?.plugins[0].id == "cached.plugin")
    }

    @Test func cachedRegistryReturnsNilWhenExpired() async throws {
        let tempDir = makeTestTempDir(label: "RegistryManagerTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let toml = """
        name = "Expired Registry"
        url = "https://github.com/test/test"
        """

        let cacheFile = tempDir.appendingPathComponent("registry.toml")
        try toml.write(to: cacheFile, atomically: true, encoding: .utf8)

        // Set modification date to past
        let pastDate = Date(timeIntervalSinceNow: -48 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: cacheFile.path)

        let manager = RegistryManager(
            registryURL: URL(string: "https://example.com/registry.toml")!,
            cacheURL: cacheFile,
            ttl: 24 * 60 * 60 // 24 hours
        )

        let cached = try await manager.cachedRegistry()
        #expect(cached == nil)
    }
}

// MARK: - InstallManifest Tests

struct InstallManifestTests {
    @Test func readWriteRoundTrip() throws {
        let tempDir = makeTestTempDir(label: "InstallManifestTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("install.toml")
        let info = InstallInfo(
            sourceURL: URL(string: "https://example.com/plugin.toml")!,
            installedVersion: "1.2.3",
            installedAt: Date(timeIntervalSince1970: 1_000_000),
            pinnedRef: "abc123"
        )

        try InstallManifest.write(info, to: url)
        let read = try InstallManifest.read(from: url)

        #expect(read.sourceURL == info.sourceURL)
        #expect(read.installedVersion == info.installedVersion)
        #expect(read.pinnedRef == info.pinnedRef)
    }

    @Test func readMissingFile() {
        let tempDir = makeTestTempDir(label: "InstallManifestTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("nonexistent.toml")
        #expect(throws: Swift.Error.self) {
            try InstallManifest.read(from: url)
        }
    }
}

// MARK: - PluginMarket Tests

struct PluginMarketTests {
    @Test func listInstalledEmpty() async {
        let tempDir = makeTestTempDir(label: "PluginMarketTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let market = PluginMarket(pluginsDirectory: tempDir)
        let installed = await market.listInstalled()
        #expect(installed.isEmpty)
    }

    @Test func listInstalledWithPlugins() async throws {
        let tempDir = makeTestTempDir(label: "PluginMarketTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a manually placed plugin
        try writeTestPlugin(in: tempDir, name: "test.manual", toml: """
            [plugin]
            id = "test.manual"
            name = "Manual Plugin"
            version = "1.0.0"
        """, lua: "function search(query) return {} end")

        let market = PluginMarket(pluginsDirectory: tempDir)
        let installed = await market.listInstalled()
        #expect(installed.count == 1)
        #expect(installed[0].id == "test.manual")
        #expect(installed[0].status == .manuallyPlaced)
    }

    @Test func listInstalledWithInstallToml() async throws {
        let tempDir = makeTestTempDir(label: "PluginMarketTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pluginDir = tempDir.appendingPathComponent("test.installed")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        try """
            [plugin]
            id = "test.installed"
            name = "Installed Plugin"
            version = "1.0.0"
        """.write(to: pluginDir.appendingPathComponent("plugin.toml"), atomically: true, encoding: .utf8)

        try """
            function search(query) return {} end
        """.write(to: pluginDir.appendingPathComponent("plugin.lua"), atomically: true, encoding: .utf8)

        let installInfo = InstallInfo(
            sourceURL: URL(string: "https://example.com/plugin.toml")!,
            installedVersion: "1.0.0",
            installedAt: Date(),
            pinnedRef: ""
        )
        try InstallManifest.write(installInfo, to: pluginDir.appendingPathComponent("install.toml"))

        let market = PluginMarket(pluginsDirectory: tempDir)
        let installed = await market.listInstalled()
        #expect(installed.count == 1)
        #expect(installed[0].id == "test.installed")
        #expect(installed[0].status == .installed)
        #expect(installed[0].installInfo?.installedVersion == "1.0.0")
    }

    @Test func uninstallRemovesPlugin() async throws {
        let tempDir = makeTestTempDir(label: "PluginMarketTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeTestPlugin(in: tempDir, name: "test.remove", lua: "function search(query) return {} end")

        let market = PluginMarket(pluginsDirectory: tempDir)
        try await market.uninstall(id: "test.remove")

        let installed = await market.listInstalled()
        #expect(installed.isEmpty)
    }

    @Test func uninstallNotInstalled() async {
        let tempDir = makeTestTempDir(label: "PluginMarketTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let market = PluginMarket(pluginsDirectory: tempDir)
        await #expect(throws: PluginMarketError.notInstalled("missing")) {
            try await market.uninstall(id: "missing")
        }
    }

    @Test func checkUpdatesDetectsNewVersion() async throws {
        let tempDir = makeTestTempDir(label: "PluginMarketTests")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cacheDir = makeTestTempDir(label: "RegistryCache")
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Create installed plugin
        let pluginDir = tempDir.appendingPathComponent("test.update")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        try """
            [plugin]
            id = "test.update"
            name = "Update Plugin"
            version = "1.0.0"
        """.write(to: pluginDir.appendingPathComponent("plugin.toml"), atomically: true, encoding: .utf8)
        try "function search(q) return {} end".write(to: pluginDir.appendingPathComponent("plugin.lua"), atomically: true, encoding: .utf8)

        let installInfo = InstallInfo(
            sourceURL: URL(string: "https://example.com/plugin.toml")!,
            installedVersion: "1.0.0",
            installedAt: Date(),
            pinnedRef: ""
        )
        try InstallManifest.write(installInfo, to: pluginDir.appendingPathComponent("install.toml"))

        // Create registry cache with newer version
        let registryToml = """
        name = "Test"
        url = "https://example.com"

        [[plugins]]
        id = "test.update"
        name = "Update Plugin"
        version = "1.1.0"
        source = "https://example.com/plugin.toml"
        """
        let cacheFile = cacheDir.appendingPathComponent("registry.toml")
        try registryToml.write(to: cacheFile, atomically: true, encoding: .utf8)

        let registryManager = RegistryManager(
            registryURL: URL(string: "https://example.com/registry.toml")!,
            cacheURL: cacheFile
        )
        let market = PluginMarket(pluginsDirectory: tempDir, registryManager: registryManager)

        let updates = try await market.checkUpdates()
        #expect(updates.count == 1)
        #expect(updates[0].id == "test.update")
        #expect(updates[0].currentVersion == "1.0.0")
        #expect(updates[0].latestVersion == "1.1.0")
    }
}
