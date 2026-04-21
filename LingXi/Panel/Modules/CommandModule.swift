import Foundation
import AppKit

@MainActor
final class CommandModule: SearchProviderModule, PluginAwareModule {
    let moduleId = "command"

    private let commandProvider = CommandSearchProvider()
    private let pluginManager: PluginManager

    init(pluginManager: PluginManager) {
        self.pluginManager = pluginManager
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
                subtitle: "Show loaded plugins and errors",
                icon: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"),
                action: { _ in
                    let summary = pluginManager.summary
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
