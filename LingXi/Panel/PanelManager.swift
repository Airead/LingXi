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
    private let viewModel = SearchViewModel()

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if let panel, panel.isVisible {
            return
        }

        let activePanel = panel ?? createPanel()
        self.panel = activePanel

        viewModel.clear()
        positionPanel(activePanel)
        activePanel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard isVisible else { return }
        panel?.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private func createPanel() -> FloatingPanel {
        let newPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 60))
        newPanel.contentView = NSHostingView(rootView: PanelContentView(viewModel: viewModel, onDismiss: { [weak self] in
            self?.hide()
        }))
        newPanel.onDismiss = { [weak self] in
            self?.hide()
        }
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
    @ObservedObject var viewModel: SearchViewModel
    var onDismiss: () -> Void
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            TextField("Search...", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($isSearchFieldFocused)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onExitCommand {
            onDismiss()
        }
        .onAppear {
            isSearchFieldFocused = true
        }
    }
}
