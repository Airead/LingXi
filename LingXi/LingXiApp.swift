//
//  LingXiApp.swift
//  LingXi
//
//  Created by fanrenhao on 2026/4/2.
//

import SwiftUI

#if !SPM_BUILD
@main
#endif
struct LingXiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let settings = AppSettings.shared
    private let hotKeyManager: HotKeyManager
    private let panelHolder = PanelHolder()

    @MainActor
    private final class PanelHolder {
        var panelManager: PanelManager?
    }

    var body: some Scene {
        MenuBarExtra("LingXi", systemImage: "atom") {
            MenuBarMenuView()
        }
    }

    init() {
        let s = settings
        let hotKeyManager = HotKeyManager()
        self.hotKeyManager = hotKeyManager

        let holder = panelHolder

        hotKeyManager.start()

        let showPanel: (String?) -> Void = { prefix in
            if holder.panelManager?.isVisible == false {
                holder.panelManager?.saveInputSource()
            }
            if let prefix {
                holder.panelManager?.showWithPrefix(prefix)
            } else {
                holder.panelManager?.toggle()
            }
        }

        let mainHotKeyId = hotKeyManager.register(keyCode: s.hotKeyKeyCode, modifiers: s.hotKeyModifiers) {
            showPanel(nil)
        }

        let sourceEntries: [(KeyPath<AppSettings, UInt32>, KeyPath<AppSettings, UInt32>, KeyPath<AppSettings, String>)] = [
            (\.fileSearchHotKeyKeyCode, \.fileSearchHotKeyModifiers, \.fileSearchPrefix),
            (\.folderSearchHotKeyKeyCode, \.folderSearchHotKeyModifiers, \.folderSearchPrefix),
            (\.bookmarkSearchHotKeyKeyCode, \.bookmarkSearchHotKeyModifiers, \.bookmarkSearchPrefix),
            (\.clipboardSearchHotKeyKeyCode, \.clipboardSearchHotKeyModifiers, \.clipboardSearchPrefix),
            (\.snippetSearchHotKeyKeyCode, \.snippetSearchHotKeyModifiers, \.snippetSearchPrefix),
        ]

        let sourceHotKeyIds = sourceEntries.map { kcPath, modPath, prefixPath in
            hotKeyManager.register(keyCode: s[keyPath: kcPath], modifiers: s[keyPath: modPath]) {
                showPanel(s[keyPath: prefixPath])
            }
        }

        let hk = hotKeyManager

        observeForever({
            _ = s.hotKeyKeyCode
            _ = s.hotKeyModifiers
        }, action: {
            hk.update(id: mainHotKeyId, keyCode: s.hotKeyKeyCode, modifiers: s.hotKeyModifiers)
        })

        for ((kcPath, modPath, _), hotKeyId) in zip(sourceEntries, sourceHotKeyIds) {
            observeForever({
                _ = s[keyPath: kcPath]
                _ = s[keyPath: modPath]
            }, action: {
                hk.update(id: hotKeyId, keyCode: s[keyPath: kcPath], modifiers: s[keyPath: modPath])
            })
        }

        // Screenshot hotkeys
        let screenshotRegionHotKeyId = hotKeyManager.register(
            keyCode: s.screenshotRegionHotKeyKeyCode,
            modifiers: s.screenshotRegionHotKeyModifiers
        ) {
            Task { await ScreenshotManager.shared.captureRegion() }
        }
        let screenshotFullScreenHotKeyId = hotKeyManager.register(
            keyCode: s.screenshotFullScreenHotKeyKeyCode,
            modifiers: s.screenshotFullScreenHotKeyModifiers
        ) {
            Task { await ScreenshotManager.shared.captureFullScreen() }
        }

        observeForever({
            _ = s.screenshotRegionHotKeyKeyCode
            _ = s.screenshotRegionHotKeyModifiers
        }, action: {
            hk.update(id: screenshotRegionHotKeyId, keyCode: s.screenshotRegionHotKeyKeyCode, modifiers: s.screenshotRegionHotKeyModifiers)
        })
        observeForever({
            _ = s.screenshotFullScreenHotKeyKeyCode
            _ = s.screenshotFullScreenHotKeyModifiers
        }, action: {
            hk.update(id: screenshotFullScreenHotKeyId, keyCode: s.screenshotFullScreenHotKeyKeyCode, modifiers: s.screenshotFullScreenHotKeyModifiers)
        })

        observeForever({
            _ = s.appearanceMode
        }, action: {
            applyAppearance(s.appearanceMode)
        })

        Task { @MainActor in
            let db = await DatabaseManager(databasePath: DatabaseManager.defaultDatabasePath())

            let appModule = ApplicationModule()
            let fileSearchModule = FileSearchModule()
            let bookmarkModule = BookmarkModule()
            let systemSettingsModule = SystemSettingsModule()

            let router = SearchRouter(defaultProvider: appModule.defaultProvider, maxResults: s.maxSearchResults)

            let clipboardStore = ClipboardStore(
                database: db,
                capacity: s.clipboardHistoryCapacity,
                imageDirectory: ClipboardStore.defaultImageDirectory
            )

            let snippetStore = SnippetStore()
            let snippetModule = SnippetModule(store: snippetStore)
            let leaderKeyManager = LeaderKeyManager()

            let pluginManager = PluginManager(router: router)

            let clipboardModule = ClipboardModule(store: clipboardStore, pluginManager: pluginManager)
            let commandModule = CommandModule(pluginManager: pluginManager)

            let modules: [SearchProviderModule] = [
                appModule,
                fileSearchModule,
                bookmarkModule,
                systemSettingsModule,
                clipboardModule,
                snippetModule,
                commandModule,
            ]

            for module in modules {
                module.register(router: router, settings: s)
            }

            await pluginManager.loadAll()
            for module in modules {
                if let aware = module as? PluginAwareModule {
                    await aware.afterPluginsLoaded()
                }
            }

            let viewModel = await SearchViewModel(router: router, database: db)

            let pm = PanelManager(
                settings: s,
                router: router,
                viewModel: viewModel,
                pluginService: pluginManager,
                snippetModule: snippetModule,
                leaderKeyManager: leaderKeyManager,
                modules: modules
            )
            holder.panelManager = pm

            for module in modules {
                module.bindEvents(to: viewModel, context: pm)
            }

            observeForever({
                _ = s.maxSearchResults
                _ = s.applicationSearchEnabled
                _ = s.fileSearchEnabled
                _ = s.folderSearchEnabled
                _ = s.bookmarkSearchEnabled
                _ = s.clipboardHistoryEnabled
                _ = s.fileSearchPrefix
                _ = s.folderSearchPrefix
                _ = s.bookmarkSearchPrefix
                _ = s.clipboardSearchPrefix
                _ = s.clipboardHistoryCapacity
                _ = s.snippetSearchEnabled
                _ = s.snippetSearchPrefix
            }, action: {
                pm.applySettings(s)
            })
            observeForever({
                _ = s.snippetAutoExpandEnabled
            }, action: {
                pm.setAutoExpandEnabled(s.snippetAutoExpandEnabled)
            })
            observeForever({
                _ = s.leaderKeyEnabled
            }, action: {
                pm.setLeaderKeyEnabled(s.leaderKeyEnabled)
            })
        }
    }

}

private struct MenuBarMenuView: View {
    var body: some View {
        Button("Settings...") {
            AppDelegate.showSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit LingXi") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit LingXi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func openSettings() {
        Self.showSettings()
    }

    static func showSettings() {
        SettingsWindowManager.shared.show()
    }
}

private func observeForever(_ track: @escaping () -> Void, action: @escaping @MainActor () -> Void) {
    withObservationTracking(track) {
        Task { @MainActor in
            action()
            observeForever(track, action: action)
        }
    }
}

private func applyAppearance(_ mode: AppSettings.AppearanceMode) {
    switch mode {
    case .system:
        NSApp.appearance = nil
    case .light:
        NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
