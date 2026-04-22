import Foundation
import AppKit

@MainActor
final class CommandModule: SearchProviderModule, PluginAwareModule {
    let moduleId = "command"

    private let commandProvider = CommandSearchProvider()
    private let pluginManager: PluginManager
    private let pluginMarket: PluginMarket
    private let settings: AppSettings

    init(pluginManager: PluginManager, pluginMarket: PluginMarket, settings: AppSettings) {
        self.pluginManager = pluginManager
        self.pluginMarket = pluginMarket
        self.settings = settings
        pluginManager.setCommandProvider(commandProvider)
    }

    func register(router: SearchRouter, settings: AppSettings) {
        router.register(prefix: settings.commandSearchPrefix, id: moduleId, provider: commandProvider)
        let promotedProvider = PromotedCommandSearchProvider(commandProvider: commandProvider)
        router.registerDefault(id: "command-promoted", provider: promotedProvider)
    }

    func applySettings(_ settings: AppSettings, router: SearchRouter) {
        router.setEnabled(settings.commandSearchEnabled, forId: moduleId)
        router.setEnabled(settings.commandSearchEnabled, forId: "command-promoted")
        router.updatePrefix(settings.commandSearchPrefix, forId: moduleId)
    }

    func bindEvents(to viewModel: SearchViewModel, context: PanelContext) {
        viewModel.onCommandExecute = { [weak self] result in
            guard let self else { return }
            Task {
                guard let entry = await self.commandProvider.entry(for: result.itemId) else { return }
                await entry.action(result.actionContext)
            }
        }
    }

    func afterPluginsLoaded() async {
        await registerBuiltinCommands()
        await registerPluginCommands()
    }

    func start() {}
    func stop() {}

    // MARK: - Private

    private func registerBuiltinCommands() async {
        let commands: [CommandEntry] = [
            CommandEntry(
                name: "settings", title: "Open Settings", subtitle: "Open the settings window",
                icon: NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings"),
                action: { _ in SettingsWindowManager.shared.show() },
                promoted: true
            ),
            CommandEntry(
                name: "help", title: "Show Help", subtitle: "Open settings for available prefixes",
                icon: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Help"),
                action: { _ in SettingsWindowManager.shared.show() }
            ),
            CommandEntry(
                name: "screenshot", title: "Capture Region", subtitle: "Take a screenshot of a selected region",
                icon: NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshot"),
                action: { _ in await ScreenshotManager.shared.captureRegion() }
            ),
            CommandEntry(
                name: "screenshot-fullscreen", title: "Capture Full Screen", subtitle: "Take a screenshot of the full screen",
                icon: NSImage(systemSymbolName: "camera", accessibilityDescription: "Full Screen"),
                action: { _ in await ScreenshotManager.shared.captureFullScreen() }
            ),
            CommandEntry(
                name: "reveal-clipboard-images", title: "Reveal Clipboard Images", subtitle: "Open clipboard images folder in Finder",
                icon: NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Clipboard Images"),
                action: { _ in NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ClipboardStore.defaultImageDirectory.path) }
            ),
            CommandEntry(
                name: "reveal-snippets", title: "Reveal Snippets Folder", subtitle: "Open snippets folder in Finder",
                icon: NSImage(systemSymbolName: "folder", accessibilityDescription: "Snippets"),
                action: { _ in NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: SnippetStore.defaultDirectory.path) }
            ),
            CommandEntry(
                name: "quit", title: "Quit Application", subtitle: "Quit a running application by name",
                icon: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Quit"),
                action: { args in
                    let target = args.trimmingCharacters(in: .whitespaces)
                    guard !target.isEmpty else { return }
                    for app in NSWorkspace.shared.runningApplications
                    where app.localizedName?.localizedCaseInsensitiveCompare(target) == .orderedSame {
                        app.terminate()
                    }
                }
            ),
            CommandEntry(
                name: "quit-all", title: "Quit All Applications", subtitle: "Quit all running applications except Finder and self",
                icon: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Quit All"),
                action: { _ in
                    let selfBundleId = Bundle.main.bundleIdentifier
                    for app in NSWorkspace.shared.runningApplications {
                        guard app.activationPolicy == .regular else { continue }
                        if app.bundleIdentifier == "com.apple.finder" { continue }
                        if let selfId = selfBundleId, app.bundleIdentifier == selfId { continue }
                        app.terminate()
                    }
                }
            ),
        ]
        await registerCommands(commands)
    }

    private func registerPluginCommands() async {
        let pluginManager = self.pluginManager
        let pluginMarket = self.pluginMarket
        let settings = self.settings

        let commands: [CommandEntry] = [
            CommandEntry(
                name: "plugin:reload",
                title: "Reload Plugins",
                subtitle: "Reload all Lua plugins from disk",
                icon: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload"),
                action: { _ in await pluginManager.reload() }
            ),
            CommandEntry(
                name: "plugin:list",
                title: "List Plugins",
                subtitle: "Show all installed plugins with status",
                icon: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"),
                action: { _ in
                    let installed = pluginManager.installedPlugins()
                    var lines: [String] = []
                    if installed.isEmpty {
                        lines.append("No plugins installed.")
                    } else {
                        for info in installed {
                            let version = info.manifest.version.isEmpty ? "" : " v\(info.manifest.version)"
                            let statusStr = "(\(info.status.rawValue))"
                            let source = info.installInfo?.sourceURL.absoluteString ?? "manual"
                            lines.append("[\(info.manifest.prefix)] \(info.manifest.name)\(version) \(statusStr) — \(source)")
                        }
                    }
                    let summary = lines.joined(separator: "\n")
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(summary, forType: .string)
                    DebugLog.log("[PluginManager] Plugin list copied to clipboard:\n\(summary)")
                }
            ),
            CommandEntry(
                name: "plugin:open",
                title: "Open Plugins Folder",
                subtitle: "Reveal plugins folder in Finder",
                icon: NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder"),
                action: { _ in
                    let dir = pluginManager.directory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
                }
            ),
            CommandEntry(
                name: "plugin:install",
                title: "Install Plugin",
                subtitle: "Install a plugin from registry or URL",
                icon: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Install"),
                action: { args in
                    let target = args.trimmingCharacters(in: .whitespaces)
                    guard !target.isEmpty else {
                        DebugLog.log("[PluginManager] Usage: plugin:install <id> or plugin:install <url>")
                        return
                    }
                    do {
                        if target.hasPrefix("http") {
                            guard let url = URL(string: target) else {
                                DebugLog.log("[PluginManager] Invalid URL: \(target)")
                                return
                            }
                            try await pluginMarket.install(url: url)
                        } else {
                            try await pluginMarket.install(id: target)
                        }
                        // Add to disabled list by default
                        if !settings.disabledPlugins.contains(target) {
                            settings.disabledPlugins.append(target)
                        }
                        DebugLog.log("[PluginManager] Installed \(target). Use plugin:enable to activate.")
                    } catch {
                        DebugLog.log("[PluginManager] Install failed: \(error)")
                    }
                }
            ),
            CommandEntry(
                name: "plugin:uninstall",
                title: "Uninstall Plugin",
                subtitle: "Remove a plugin from disk",
                icon: NSImage(systemSymbolName: "trash", accessibilityDescription: "Uninstall"),
                action: { args in
                    let target = args.trimmingCharacters(in: .whitespaces)
                    guard !target.isEmpty else {
                        DebugLog.log("[PluginManager] Usage: plugin:uninstall <id>")
                        return
                    }
                    do {
                        try await pluginMarket.uninstall(id: target)
                        // Remove from disabled list if present
                        settings.disabledPlugins.removeAll { $0 == target }
                        await pluginManager.reload()
                        DebugLog.log("[PluginManager] Uninstalled \(target)")
                    } catch {
                        DebugLog.log("[PluginManager] Uninstall failed: \(error)")
                    }
                }
            ),
            CommandEntry(
                name: "plugin:enable",
                title: "Enable Plugin",
                subtitle: "Enable a disabled plugin",
                icon: NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Enable"),
                action: { args in
                    let target = args.trimmingCharacters(in: .whitespaces)
                    guard !target.isEmpty else {
                        DebugLog.log("[PluginManager] Usage: plugin:enable <id>")
                        return
                    }
                    settings.disabledPlugins.removeAll { $0 == target }
                    await pluginManager.reload()
                    DebugLog.log("[PluginManager] Enabled \(target)")
                }
            ),
            CommandEntry(
                name: "plugin:disable",
                title: "Disable Plugin",
                subtitle: "Disable a plugin without removing it",
                icon: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Disable"),
                action: { args in
                    let target = args.trimmingCharacters(in: .whitespaces)
                    guard !target.isEmpty else {
                        DebugLog.log("[PluginManager] Usage: plugin:disable <id>")
                        return
                    }
                    if !settings.disabledPlugins.contains(target) {
                        settings.disabledPlugins.append(target)
                    }
                    await pluginManager.reload()
                    DebugLog.log("[PluginManager] Disabled \(target)")
                }
            ),
            CommandEntry(
                name: "plugin:update",
                title: "Update Plugin",
                subtitle: "Update a plugin or all plugins",
                icon: NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: "Update"),
                action: { args in
                    do {
                        let target = args.trimmingCharacters(in: .whitespaces)
                        if target.isEmpty {
                            // Update all
                            let updates = try await pluginMarket.checkUpdates()
                            if updates.isEmpty {
                                DebugLog.log("[PluginManager] All plugins are up to date.")
                                return
                            }
                            for update in updates {
                                DebugLog.log("[PluginManager] Updating \(update.id) from \(update.currentVersion) to \(update.latestVersion)...")
                                // Backup old plugin
                                let pluginDir = pluginManager.directory.appendingPathComponent(sanitizeDirectoryName(update.id))
                                let backupDir = pluginManager.directory.appendingPathComponent(sanitizeDirectoryName(update.id) + ".backup")
                                let fm = FileManager.default
                                if fm.fileExists(atPath: backupDir.path) {
                                    try? fm.removeItem(at: backupDir)
                                }
                                try? fm.copyItem(at: pluginDir, to: backupDir)

                                do {
                                    try await pluginMarket.uninstall(id: update.id)
                                    let registry = try await pluginMarket.listAvailable()
                                    guard let registryPlugin = registry.first(where: { $0.id == update.id }) else {
                                        throw PluginMarketError.pluginNotFound(update.id)
                                    }
                                    try await pluginMarket.install(url: registryPlugin.sourceURL)
                                    DebugLog.log("[PluginManager] Updated \(update.id) to \(update.latestVersion)")
                                    try? fm.removeItem(at: backupDir)
                                } catch {
                                    // Restore backup on failure
                                    if fm.fileExists(atPath: backupDir.path) {
                                        try? fm.removeItem(at: pluginDir)
                                        try? fm.moveItem(at: backupDir, to: pluginDir)
                                    }
                                    throw error
                                }
                            }
                            await pluginManager.reload()
                            DebugLog.log("[PluginManager] All updates completed.")
                        } else {
                            // Update single
                            let updates = try await pluginMarket.checkUpdates()
                            guard let update = updates.first(where: { $0.id == target }) else {
                                DebugLog.log("[PluginManager] No update available for \(target)")
                                return
                            }
                            let pluginDir = pluginManager.directory.appendingPathComponent(sanitizeDirectoryName(target))
                            let backupDir = pluginManager.directory.appendingPathComponent(sanitizeDirectoryName(target) + ".backup")
                            let fm = FileManager.default
                            if fm.fileExists(atPath: backupDir.path) {
                                try? fm.removeItem(at: backupDir)
                            }
                            try? fm.copyItem(at: pluginDir, to: backupDir)

                            do {
                                try await pluginMarket.uninstall(id: target)
                                let registry = try await pluginMarket.listAvailable()
                                guard let registryPlugin = registry.first(where: { $0.id == target }) else {
                                    throw PluginMarketError.pluginNotFound(target)
                                }
                                try await pluginMarket.install(url: registryPlugin.sourceURL)
                                DebugLog.log("[PluginManager] Updated \(target) to \(update.latestVersion)")
                                try? fm.removeItem(at: backupDir)
                            } catch {
                                if fm.fileExists(atPath: backupDir.path) {
                                    try? fm.removeItem(at: pluginDir)
                                    try? fm.moveItem(at: backupDir, to: pluginDir)
                                }
                                throw error
                            }
                            await pluginManager.reload()
                        }
                    } catch {
                        DebugLog.log("[PluginManager] Update failed: \(error)")
                    }
                }
            ),
            CommandEntry(
                name: "plugin:registry",
                title: "Registry Refresh",
                subtitle: "Force refresh the plugin registry cache",
                icon: NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: "Registry"),
                action: { args in
                    do {
                        _ = try await pluginMarket.listAvailable()
                        DebugLog.log("[PluginManager] Registry refreshed.")
                    } catch {
                        DebugLog.log("[PluginManager] Registry refresh failed: \(error)")
                    }
                }
            ),
        ]
        await registerCommands(commands)
    }

    private func registerCommands(_ commands: [CommandEntry]) async {
        for cmd in commands {
            do {
                try await commandProvider.register(cmd)
            } catch {
                assertionFailure("Failed to register command '\(cmd.name)': \(error)")
            }
        }
    }
}
