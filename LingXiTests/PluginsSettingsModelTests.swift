import Foundation
import Testing
@testable import LingXi

@MainActor
struct PluginsSettingsModelTests {
    /// Isolated model fixture: temp plugins dir, file:// registry, in-memory-ish
    /// UserDefaults suite. Nothing touches real user data.
    @MainActor
    private struct Fixture {
        let root: URL
        let pluginsDir: URL
        let sourceDir: URL
        let cacheFile: URL
        let settings: AppSettings
        let pluginManager: PluginManager
        let market: PluginMarket
        let model: PluginsSettingsModel

        init(label: String, registryURL: URL? = nil) {
            root = makeTestTempDir(label: label)
            pluginsDir = root.appendingPathComponent("plugins")
            sourceDir = root.appendingPathComponent("source")
            cacheFile = root.appendingPathComponent("registry.toml")
            try! FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

            let suiteName = "io.github.airead.lingxi.test.\(UUID().uuidString)"
            settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)

            let registryManager = RegistryManager(
                registryURL: registryURL ?? URL(string: "https://example.com/registry.toml")!,
                cacheURL: cacheFile
            )
            pluginManager = PluginManager(router: emptyRouter(), directory: pluginsDir, settings: settings)
            market = PluginMarket(pluginsDirectory: pluginsDir, registryManager: registryManager)
            model = PluginsSettingsModel(pluginManager: pluginManager, pluginMarket: market, settings: settings)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Merge

    @Test func refreshMergesInstalledAndAvailable() async throws {
        let fixture = Fixture(label: "ModelMerge")
        defer { fixture.remove() }

        let sourceURL = URL(string: "https://example.com/plugin.toml")!
        try writeInstalledPlugin(in: fixture.pluginsDir, id: "test.installed", version: "1.0.0", sourceURL: sourceURL)
        try writeTestPlugin(in: fixture.pluginsDir, name: "test.manual", toml: """
            [plugin]
            id = "test.manual"
            name = "Manual"
            version = "1.0.0"
        """, lua: "function search(query) return {} end")
        try writeInstalledPlugin(in: fixture.pluginsDir, id: "test.disabled", version: "1.0.0", sourceURL: sourceURL)
        fixture.settings.disabledPlugins = ["test.disabled"]

        // Registry: the installed plugin + one extra not on disk.
        try """
            name = "Test Registry"
            url = "https://example.com/test"

            [[plugins]]
            id = "test.installed"
            name = "test.installed"
            version = "1.0.0"
            author = "Tester"
            source = "https://example.com/plugin.toml"

            [[plugins]]
            id = "test.extra"
            name = "test.extra"
            version = "2.0.0"
            author = "Tester"
            source = "https://example.com/extra/plugin.toml"
            """.write(to: fixture.cacheFile, atomically: true, encoding: .utf8)

        await fixture.model.refresh()

        #expect(fixture.model.registryLoadFailed == false)
        let statusByID = Dictionary(uniqueKeysWithValues: fixture.model.installedRows.map { ($0.id, $0.status) })
        #expect(statusByID == [
            "test.installed": .installed,
            "test.manual": .manuallyPlaced,
            "test.disabled": .disabled,
        ])
        #expect(fixture.model.installedRows.allSatisfy { $0.permissions != nil })

        #expect(fixture.model.availableRows.map(\.id) == ["test.extra"])
        #expect(fixture.model.availableRows[0].status == .notInstalled)
        #expect(fixture.model.availableRows[0].permissions == nil)
        #expect(fixture.model.availableRows[0].version == "2.0.0")
    }

    @Test func refreshDerivesUpdateAvailable() async throws {
        let fixture = Fixture(label: "ModelUpdateStatus")
        defer { fixture.remove() }

        let sourceURL = URL(string: "https://example.com/plugin.toml")!
        try writeInstalledPlugin(in: fixture.pluginsDir, id: "test.old", version: "1.0.0", sourceURL: sourceURL)
        try writeInstalledPlugin(in: fixture.pluginsDir, id: "test.disabled", version: "1.0.0", sourceURL: sourceURL)
        fixture.settings.disabledPlugins = ["test.disabled"]
        try writeTestPlugin(in: fixture.pluginsDir, name: "test.manual", toml: """
            [plugin]
            id = "test.manual"
            name = "Manual"
            version = "1.0.0"
        """, lua: "function search(query) return {} end")

        try """
            name = "Test Registry"
            url = "https://example.com/test"

            [[plugins]]
            id = "test.old"
            name = "test.old"
            version = "1.1.0"
            source = "https://example.com/plugin.toml"

            [[plugins]]
            id = "test.disabled"
            name = "test.disabled"
            version = "1.1.0"
            source = "https://example.com/plugin.toml"

            [[plugins]]
            id = "test.manual"
            name = "test.manual"
            version = "9.9.9"
            source = "https://example.com/plugin.toml"
            """.write(to: fixture.cacheFile, atomically: true, encoding: .utf8)

        await fixture.model.refresh()

        let rowsByID = Dictionary(uniqueKeysWithValues: fixture.model.installedRows.map { ($0.id, $0) })
        // Enabled market install with newer registry version surfaces as updateAvailable.
        #expect(rowsByID["test.old"]?.status == .updateAvailable)
        #expect(rowsByID["test.old"]?.latestVersion == "1.1.0")
        // Disabled keeps its status but still shows the newer version.
        #expect(rowsByID["test.disabled"]?.status == .disabled)
        #expect(rowsByID["test.disabled"]?.latestVersion == "1.1.0")
        // Manual plugins never get updates (no install.toml).
        #expect(rowsByID["test.manual"]?.status == .manuallyPlaced)
        #expect(rowsByID["test.manual"]?.latestVersion == nil)
    }

    @Test func refreshSurvivesRegistryFailure() async throws {
        let fixture = Fixture(
            label: "ModelOffline",
            registryURL: URL(fileURLWithPath: "/nonexistent/registry.toml")
        )
        defer { fixture.remove() }

        try writeTestPlugin(in: fixture.pluginsDir, name: "test.manual", toml: """
            [plugin]
            id = "test.manual"
            name = "Manual"
            version = "1.0.0"
        """, lua: "function search(query) return {} end")

        await fixture.model.refresh()

        #expect(fixture.model.registryLoadFailed == true)
        #expect(fixture.model.installedRows.map(\.id) == ["test.manual"])
        #expect(fixture.model.availableRows.isEmpty)
    }

    // MARK: - Actions

    @Test func installAction() async throws {
        let fixture = Fixture(label: "ModelInstall")
        defer { fixture.remove() }

        let manifestURL = try writeMarketSourcePlugin(in: fixture.sourceDir, id: "test.market", version: "1.0.0")
        try writeRegistryTOML(to: fixture.cacheFile, id: "test.market", version: "1.0.0", sourceURL: manifestURL)

        await fixture.model.install(id: "test.market")

        #expect(fixture.model.errorMessage == nil)
        #expect(fixture.settings.disabledPlugins.contains("test.market"))
        #expect(fixture.model.installedRows.map(\.id) == ["test.market"])
        #expect(fixture.model.installedRows[0].status == .disabled)
        #expect(fixture.model.availableRows.isEmpty)
        #expect(fixture.model.busyPluginIDs.isEmpty)
    }

    @Test func enableDisableActions() async throws {
        let fixture = Fixture(label: "ModelEnable")
        defer { fixture.remove() }

        try writeTestPlugin(in: fixture.pluginsDir, name: "test.manual", toml: """
            [plugin]
            id = "test.manual"
            name = "Manual"
            version = "1.0.0"
        """, lua: "function search(query) return {} end")

        await fixture.model.setEnabled(false, id: "test.manual")
        #expect(fixture.settings.disabledPlugins == ["test.manual"])
        #expect(fixture.model.installedRows[0].status == .disabled)
        #expect(fixture.pluginManager.plugins.isEmpty)

        await fixture.model.setEnabled(true, id: "test.manual")
        #expect(fixture.settings.disabledPlugins.isEmpty)
        #expect(fixture.model.installedRows[0].status == .manuallyPlaced)
        #expect(fixture.pluginManager.plugins.count == 1)
    }

    @Test func uninstallAction() async throws {
        let fixture = Fixture(label: "ModelUninstall")
        defer { fixture.remove() }

        let manifestURL = try writeMarketSourcePlugin(in: fixture.sourceDir, id: "test.market", version: "1.0.0")
        try writeRegistryTOML(to: fixture.cacheFile, id: "test.market", version: "1.0.0", sourceURL: manifestURL)
        try writeInstalledPlugin(in: fixture.pluginsDir, id: "test.market", version: "1.0.0", sourceURL: manifestURL)
        fixture.settings.disabledPlugins = ["test.market"]

        await fixture.model.uninstall(id: "test.market")

        #expect(fixture.model.errorMessage == nil)
        #expect(fixture.settings.disabledPlugins.isEmpty)
        #expect(fixture.model.installedRows.isEmpty)
        // Still in the registry, so it reappears as available.
        #expect(fixture.model.availableRows.map(\.id) == ["test.market"])
        let pluginDir = fixture.pluginsDir.appendingPathComponent("test.market")
        #expect(!FileManager.default.fileExists(atPath: pluginDir.path))
    }

    @Test func updateAllAction() async throws {
        let fixture = Fixture(label: "ModelUpdateAll")
        defer { fixture.remove() }

        let manifestURL = try writeMarketSourcePlugin(in: fixture.sourceDir, id: "test.market", version: "1.1.0")
        try writeRegistryTOML(to: fixture.cacheFile, id: "test.market", version: "1.1.0", sourceURL: manifestURL)
        try writeInstalledPlugin(in: fixture.pluginsDir, id: "test.market", version: "1.0.0", sourceURL: manifestURL)

        await fixture.model.refresh()
        #expect(fixture.model.hasUpdates)

        await fixture.model.updateAll()

        #expect(fixture.model.errorMessage == nil)
        #expect(fixture.model.busyPluginIDs.isEmpty)
        #expect(fixture.model.installedRows[0].status == .installed)
        #expect(fixture.model.installedRows[0].version == "1.1.0")
        #expect(fixture.model.installedRows[0].latestVersion == nil)
    }

    @Test func actionFailureSetsErrorMessage() async throws {
        let fixture = Fixture(label: "ModelFailure")
        defer { fixture.remove() }

        try writeRegistryTOML(to: fixture.cacheFile, id: "test.other", version: "1.0.0",
                              sourceURL: URL(string: "https://example.com/plugin.toml")!)

        await fixture.model.uninstall(id: "test.missing")

        #expect(fixture.model.errorMessage != nil)
        #expect(fixture.model.busyPluginIDs.isEmpty)
        #expect(fixture.model.installedRows.isEmpty)
    }
}
