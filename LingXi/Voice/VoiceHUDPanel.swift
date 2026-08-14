//
//  VoiceHUDPanel.swift
//  LingXi
//

import AppKit
import SwiftUI

// MARK: - Presenting protocol (test seam)

/// Display-only feedback while a voice session is active. Never takes focus.
@MainActor
protocol VoiceHUDPresenting: AnyObject {
    func show()
    func hide()
}

// MARK: - Layout

private enum VoiceHUDLayout {
    static let width: CGFloat = 420
    static let height: CGFloat = 44
    static let cornerRadius: CGFloat = 12
    static let bottomOffset: CGFloat = 80
    static let fadeIn: TimeInterval = 0.15
    static let fadeOut: TimeInterval = 0.2
}

// MARK: - Panel

/// Borderless non-activating panel at the bottom of the main screen showing
/// recording level, live partial text and the current pipeline phase. Pure
/// display: ignores mouse events and never becomes key.
@MainActor
final class VoiceHUDPanel: VoiceHUDPresenting {
    private let activityModel: VoiceActivityModel
    private var panel: NSPanel?

    init(activityModel: VoiceActivityModel) {
        self.activityModel = activityModel
    }

    func show() {
        if let panel {
            positionPanel(panel)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: VoiceHUDLayout.width, height: VoiceHUDLayout.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.ignoresMouseEvents = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: VoiceHUDContent(model: activityModel))
        hostingView.frame = NSRect(x: 0, y: 0, width: VoiceHUDLayout.width, height: VoiceHUDLayout.height)
        newPanel.contentView = hostingView

        positionPanel(newPanel)
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        panel = newPanel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = VoiceHUDLayout.fadeIn
            newPanel.animator().alphaValue = 1.0
        }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = VoiceHUDLayout.fadeOut
            p.animator().alphaValue = 0.0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let x = sf.midX - panel.frame.width / 2
        let y = sf.minY + VoiceHUDLayout.bottomOffset
        panel.setFrameOrigin(NSPoint(x: x, y: max(sf.minY, min(y, sf.maxY - panel.frame.height))))
    }
}

// MARK: - Content

private struct VoiceHUDContent: View {
    let model: VoiceActivityModel

    var body: some View {
        HStack(spacing: 10) {
            statusIndicator
            statusText
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: VoiceHUDLayout.width, height: VoiceHUDLayout.height)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: VoiceHUDLayout.cornerRadius))
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch model.phase {
        case .recording:
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                // RMS of speech rarely exceeds ~0.35; amplify for feedback.
                .scaleEffect(1.0 + min(model.level * 4, 1.2))
                .animation(.linear(duration: 0.1), value: model.level)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .enhancing:
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.phase {
        case .recording:
            if model.partialText.isEmpty {
                Text("Listening…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Text(model.partialText)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        case .transcribing:
            Text("Transcribing…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case .enhancing:
            Text("Polishing…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }
}
