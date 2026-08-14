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
    private let voiceActivity = VoiceActivityModel()

    @MainActor
    private final class PanelHolder {
        var panelManager: PanelManager?
        var pluginManager: PluginManager?
        var voiceInputController: VoiceInputController?
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuView(voiceController: { [holder = panelHolder] in holder.voiceInputController })
        } label: {
            MenuBarIconView(activity: voiceActivity)
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

        let voiceActivity = voiceActivity
        Task { @MainActor in
            let result = await AppAssembly.assemble(settings: s, voiceActivity: voiceActivity)
            let pm = result.panelManager
            holder.panelManager = pm
            holder.pluginManager = result.pluginManager
            holder.voiceInputController = result.voiceInputController

            let voice = result.voiceInputController
            let leader = result.leaderKeyManager
            let applyVoiceSettings: @MainActor () -> Void = {
                voice.applySettings()
                leader.setExcludedTriggers(s.voiceInputEnabled ? ["fn"] : [])
            }
            applyVoiceSettings()
            observeForever({
                _ = s.voiceInputEnabled
            }, action: {
                applyVoiceSettings()
            })

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

private struct MenuBarIconView: View {
    var activity: VoiceActivityModel

    var body: some View {
        Image(systemName: activity.symbolName)
    }
}

private struct MenuBarMenuView: View {
    var voiceController: @MainActor () -> VoiceInputController?
    private let updater = UpdateController.shared

    init(voiceController: @escaping @MainActor () -> VoiceInputController?) {
        self.voiceController = voiceController
    }

    var body: some View {
        updateMenuItems
        Button("Show Last Preview") {
            voiceController()?.showLastPreview()
        }
        Divider()
        Button("About LingXi") {
            AppDelegate.showAbout()
        }
        Button("Settings...") {
            AppDelegate.showSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Restart LingXi") {
            AppDelegate.relaunch()
        }
        Button("Quit LingXi") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var updateMenuItems: some View {
        switch updater.state {
        case .available(let v):
            Button("Update available: \(v)") { updater.handleMenuClick() }
            Divider()
        case .downloading(let msg):
            Text(msg)
            Divider()
        case .ready(let v):
            Button("Restart to update \(v)") { updater.handleMenuClick() }
            Divider()
        case .idle:
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        UpdateController.shared.start()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About LingXi", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let restartItem = NSMenuItem(title: "Restart LingXi", action: #selector(restartApp), keyEquivalent: "")
        restartItem.target = self
        appMenu.addItem(restartItem)
        appMenu.addItem(NSMenuItem(title: "Quit LingXi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func restartApp() {
        Self.relaunch()
    }

    /// Quit and re-launch the running app bundle.
    ///
    /// Spawns a detached bash that waits for this PID to exit, then
    /// `open`s the bundle. Honors `LINGXI_APP_PATH` for testability.
    static func relaunch() {
        let appURL: URL
        if let override = ProcessInfo.processInfo.environment["LINGXI_APP_PATH"] {
            appURL = URL(fileURLWithPath: override)
        } else {
            appURL = Bundle.main.bundleURL
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = relaunchScript(pid: pid, appPath: appURL.path)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        do {
            try proc.run()
        } catch {
            DebugLog.log("[Restart] Failed to spawn relaunch script: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    nonisolated static func relaunchScript(pid: pid_t, appPath: String) -> String {
        let q = "'" + appPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.2
        done
        sleep 0.3
        open \(q)
        """
    }

    @objc func openSettings() {
        Self.showSettings()
    }

    static func showSettings() {
        SettingsWindowManager.shared.show()
    }

    @objc func openAbout() {
        Self.showAbout()
    }

    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
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
