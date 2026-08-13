//
//  PluginsSettingsModel.swift
//  LingXi
//

import Foundation

/// A single row in the Plugins settings tab, merged from installed plugins
/// and the registry.
nonisolated struct PluginRowModel: Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    /// Newer registry version, if any (also shown for disabled/manual rows).
    let latestVersion: String?
    let status: PluginStatus
    let description: String
    let author: String
    let sourceURL: URL?
    /// nil for plugins that are not installed (the registry carries no permissions).
    let permissions: PermissionConfig?
    let isInstalled: Bool
}

/// State and actions backing `PluginsSettingsView`.
@Observable
final class PluginsSettingsModel {
    private let pluginManager: PluginManager
    private let pluginMarket: PluginMarket
    private let settings: AppSettings

    private(set) var installedRows: [PluginRowModel] = []
    private(set) var availableRows: [PluginRowModel] = []
    private(set) var busyPluginIDs: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var registryLoadFailed = false
    var errorMessage: String?
    /// Drives the uninstall confirmation dialog.
    var pendingUninstallID: String?

    var hasUpdates: Bool {
        installedRows.contains { $0.status == .updateAvailable }
    }

    init(pluginManager: PluginManager, pluginMarket: PluginMarket, settings: AppSettings) {
        self.pluginManager = pluginManager
        self.pluginMarket = pluginMarket
        self.settings = settings
    }

    // MARK: - Refresh

    func refresh(forceRegistry: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let installed = pluginManager.installedPlugins()

        var available: [RegistryPlugin] = []
        do {
            if forceRegistry {
                available = try await pluginMarket.refreshRegistry()
                    .plugins.sorted { $0.id < $1.id }
            } else {
                available = try await pluginMarket.listAvailable()
            }
            registryLoadFailed = false
        } catch {
            registryLoadFailed = true
            DebugLog.log("[PluginsSettings] Registry load failed: \(error)")
        }

        let registryByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })

        installedRows = installed.map { info in
            let registryPlugin = registryByID[info.id]
            let installedVersion = info.installInfo?.installedVersion ?? info.manifest.version

            var latestVersion: String?
            if let registryPlugin, info.installInfo != nil,
               Semver.compare(installedVersion, registryPlugin.version) == .orderedAscending {
                latestVersion = registryPlugin.version
            }

            // Only an enabled, market-installed plugin surfaces as updateAvailable;
            // disabled/manuallyPlaced keep their status (latestVersion still shown).
            var status = info.status
            if status == .installed, latestVersion != nil {
                status = .updateAvailable
            }

            return PluginRowModel(
                id: info.id,
                name: info.manifest.name,
                version: installedVersion,
                latestVersion: latestVersion,
                status: status,
                description: info.manifest.description,
                author: info.manifest.author,
                sourceURL: info.installInfo?.sourceURL,
                permissions: info.manifest.permissions,
                isInstalled: true
            )
        }

        let installedIDs = Set(installed.map(\.id))
        availableRows = available
            .filter { !installedIDs.contains($0.id) }
            .map { plugin in
                PluginRowModel(
                    id: plugin.id,
                    name: plugin.name,
                    version: plugin.version,
                    latestVersion: nil,
                    status: .notInstalled,
                    description: plugin.description,
                    author: plugin.author,
                    sourceURL: plugin.sourceURL,
                    permissions: nil,
                    isInstalled: false
                )
            }
    }

    // MARK: - Actions

    func install(id: String) async {
        await perform(id: id) {
            let pluginId = try await self.pluginMarket.install(id: id)
            // Installed plugins start disabled; the user enables them explicitly.
            if !self.settings.disabledPlugins.contains(pluginId) {
                self.settings.disabledPlugins.append(pluginId)
            }
            await self.pluginManager.reload()
        }
    }

    func uninstall(id: String) async {
        await perform(id: id) {
            try await self.pluginMarket.uninstall(id: id)
            self.settings.disabledPlugins.removeAll { $0 == id }
            await self.pluginManager.reload()
        }
    }

    func setEnabled(_ enabled: Bool, id: String) async {
        await perform(id: id) {
            if enabled {
                self.settings.disabledPlugins.removeAll { $0 == id }
            } else if !self.settings.disabledPlugins.contains(id) {
                self.settings.disabledPlugins.append(id)
            }
            await self.pluginManager.reload()
        }
    }

    func update(id: String) async {
        await perform(id: id) {
            try await self.pluginMarket.update(id: id)
            await self.pluginManager.reload()
        }
    }

    func updateAll() async {
        let ids = installedRows.filter { $0.status == .updateAvailable }.map(\.id)
        guard !ids.isEmpty else { return }
        errorMessage = nil
        busyPluginIDs.formUnion(ids)
        defer { busyPluginIDs.subtract(ids) }
        do {
            for id in ids {
                try await pluginMarket.update(id: id)
            }
            await pluginManager.reload()
        } catch {
            errorMessage = "Update failed: \(error)"
            DebugLog.log("[PluginsSettings] \(errorMessage!)")
        }
        await refresh()
    }

    // MARK: - Private

    /// Common action wrapper: busy guard, error capture, refresh afterwards.
    private func perform(id: String, _ operation: () async throws -> Void) async {
        guard !busyPluginIDs.contains(id) else { return }
        busyPluginIDs.insert(id)
        errorMessage = nil
        defer { busyPluginIDs.remove(id) }
        do {
            try await operation()
        } catch {
            errorMessage = "\(id): \(error)"
            DebugLog.log("[PluginsSettings] Action failed for \(id): \(error)")
        }
        await refresh()
    }
}
