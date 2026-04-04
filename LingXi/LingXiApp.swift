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
    private let panelManager: PanelManager

    var body: some Scene {
        MenuBarExtra("LingXi", systemImage: "magnifyingglass") {
            MenuBarMenuView()
        }
    }

    init() {
        let s = settings
        hotKeyManager = HotKeyManager(keyCode: s.hotKeyKeyCode, modifiers: s.hotKeyModifiers)
        panelManager = PanelManager(settings: s)

        hotKeyManager.onHotKey = { [panelManager] in
            panelManager.toggle()
        }
        hotKeyManager.start()

        let hk = hotKeyManager
        let pm = panelManager

        observeForever({
            _ = s.hotKeyKeyCode
            _ = s.hotKeyModifiers
        }, action: {
            hk.updateHotKey(keyCode: s.hotKeyKeyCode, modifiers: s.hotKeyModifiers)
        })

        observeForever({
            _ = s.maxSearchResults
            _ = s.applicationSearchEnabled
            _ = s.fileSearchEnabled
            _ = s.folderSearchEnabled
            _ = s.bookmarkSearchEnabled
            _ = s.fileSearchPrefix
            _ = s.folderSearchPrefix
            _ = s.bookmarkSearchPrefix
        }, action: {
            pm.applySettings(s)
        })

        observeForever({
            _ = s.appearanceMode
        }, action: {
            applyAppearance(s.appearanceMode)
        })
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
