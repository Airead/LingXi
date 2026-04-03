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
    private let hotKeyManager = HotKeyManager()
    private let panelManager = PanelManager()

    var body: some Scene {
        MenuBarExtra("LingXi", systemImage: "magnifyingglass") {
            Button("Quit LingXi") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    init() {
        hotKeyManager.onHotKey = { [panelManager] in
            panelManager.toggle()
        }
        hotKeyManager.start()
    }
}
