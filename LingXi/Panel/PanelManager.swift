//
//  PanelManager.swift
//  LingXi
//
//  Created by fanrenhao on 2026/4/2.
//

import AppKit
import SwiftUI

@MainActor
final class PanelManager {
    private var panel: FloatingPanel?

    func show() {
        if let panel, panel.isVisible {
            return
        }

        let activePanel = panel ?? createPanel()
        self.panel = activePanel

        positionPanel(activePanel)
        activePanel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private func createPanel() -> FloatingPanel {
        let newPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 60))
        newPanel.contentView = NSHostingView(rootView: PanelContentView())
        return newPanel
    }

    private func positionPanel(_ panel: FloatingPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panel.frame.width / 2
        let y = screenFrame.midY + screenFrame.height / 4 - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct PanelContentView: View {
    var body: some View {
        Text("LingXi")
            .font(.system(size: 24, weight: .light))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
