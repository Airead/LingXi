//
//  SettingsWindowManager.swift
//  LingXi
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    private var window: NSWindow?
    private var closeObserver: Any?
    private var pluginManager: PluginManager?
    private var pluginMarket: PluginMarket?
    private var pluginsModel: PluginsSettingsModel?

    /// Provide the plugin system dependencies so the Plugins tab can manage
    /// the market. Called once from AppAssembly.
    func configure(pluginManager: PluginManager, pluginMarket: PluginMarket) {
        self.pluginManager = pluginManager
        self.pluginMarket = pluginMarket
        self.pluginsModel = nil // rebuilt lazily with the new dependencies
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if pluginsModel == nil, let pluginManager, let pluginMarket {
            pluginsModel = PluginsSettingsModel(
                pluginManager: pluginManager,
                pluginMarket: pluginMarket,
                settings: AppSettings.shared
            )
        }

        let settingsView = SettingsView(settings: AppSettings.shared, pluginsModel: pluginsModel)
        let hostingController = NSHostingController(rootView: settingsView)

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "LingXi Settings"
        newWindow.styleMask = [.titled, .closable]
        newWindow.setContentSize(NSSize(width: 750, height: 420))
        newWindow.center()
        newWindow.isReleasedWhenClosed = false

        self.window = newWindow
        if let old = closeObserver { NotificationCenter.default.removeObserver(old) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: newWindow, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self {
                    NotificationCenter.default.removeObserver(self.closeObserver as Any)
                    self.closeObserver = nil
                    self.window = nil
                }
            }
        }

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
