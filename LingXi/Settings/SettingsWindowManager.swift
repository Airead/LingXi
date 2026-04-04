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

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(settings: AppSettings.shared)
        let hostingController = NSHostingController(rootView: settingsView)

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "LingXi Settings"
        newWindow.styleMask = [.titled, .closable]
        newWindow.setContentSize(NSSize(width: 650, height: 420))
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
