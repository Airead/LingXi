//
//  LingXiApp.swift
//  LingXi
//
//  Created by fanrenhao on 2026/4/2.
//

import SwiftUI

@main
struct LingXiApp: App {
    var body: some Scene {
        MenuBarExtra("LingXi", systemImage: "magnifyingglass") {
            Button("Quit LingXi") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
