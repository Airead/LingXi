import AppKit
import SwiftUI

/// A floating HUD-style panel that displays available leader key mappings.
///
/// Uses NSVisualEffectView for native macOS vibrancy with fade animations,
/// similar to the WenZi leader alert panel.
private enum LeaderKeyLayout {
    static let panelWidth: CGFloat = 360
    static let padding: CGFloat = 20
    static let titleHeight: CGFloat = 30
    static let gapAfterTitle: CGFloat = 8
    static let separatorHeight: CGFloat = 1
    static let gapAfterSeparator: CGFloat = 8
    static let rowHeight: CGFloat = 32
    static let cornerRadius: CGFloat = 14
    static let fadeIn: TimeInterval = 0.15
    static let fadeOut: TimeInterval = 0.2
}

@MainActor
final class LeaderKeyPanel {

    // MARK: - State

    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    // MARK: - Show

    func show(triggerKey: String, mappings: [LeaderMapping], position: PanelPosition) {
        if panel != nil { close(animated: false) }

        let rowCount = mappings.count
        let panelHeight = LeaderKeyLayout.padding
            + LeaderKeyLayout.titleHeight
            + LeaderKeyLayout.gapAfterTitle
            + LeaderKeyLayout.separatorHeight
            + LeaderKeyLayout.gapAfterSeparator
            + CGFloat(rowCount) * LeaderKeyLayout.rowHeight
            + LeaderKeyLayout.padding

        // Create borderless, transparent panel
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: LeaderKeyLayout.panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.ignoresMouseEvents = true
        newPanel.isMovableByWindowBackground = false
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // SwiftUI content
        let contentView = LeaderKeyPanelContent(
            triggerKey: triggerKey,
            mappings: mappings
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: LeaderKeyLayout.panelWidth, height: panelHeight)
        newPanel.contentView = hostingView

        // Position
        positionPanel(newPanel, position: position)

        // Fade in
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        self.panel = newPanel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = LeaderKeyLayout.fadeIn
            newPanel.animator().alphaValue = 1.0
        }
    }

    // MARK: - Close

    func close(animated: Bool = true) {
        guard let p = panel else { return }
        panel = nil  // mark closed immediately for isVisible

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = LeaderKeyLayout.fadeOut
                p.animator().alphaValue = 0.0
            }, completionHandler: {
                p.orderOut(nil)
            })
        } else {
            p.orderOut(nil)
        }
    }

    // MARK: - Positioning

    private func positionPanel(_ panel: NSPanel, position: PanelPosition) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let pw = panel.frame.width
        let ph = panel.frame.height

        var x: CGFloat
        var y: CGFloat

        switch position {
        case .center:
            x = sf.midX - pw / 2
            y = sf.midY - ph / 2
        case .top:
            x = sf.midX - pw / 2
            y = sf.maxY - ph - 100
        case .bottom:
            x = sf.midX - pw / 2
            y = sf.minY + 100
        case .mouse:
            let loc = NSEvent.mouseLocation
            x = loc.x - pw / 2
            y = loc.y - ph / 2
        }

        // Clamp to screen bounds
        x = max(sf.minX, min(x, sf.maxX - pw))
        y = max(sf.minY, min(y, sf.maxY - ph))

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI content

private struct LeaderKeyPanelContent: View {
    let triggerKey: String
    let mappings: [LeaderMapping]

    private typealias L = LeaderKeyLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Leader: \(triggerKey)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, L.padding)
                .frame(height: L.titleHeight, alignment: .leading)

            Spacer().frame(height: L.gapAfterTitle)
            Divider()
                .padding(.horizontal, L.padding)
            Spacer().frame(height: L.gapAfterSeparator)

            ForEach(Array(mappings.enumerated()), id: \.offset) { _, mapping in
                LeaderKeyRow(mapping: mapping)
            }
        }
        .padding(.vertical, L.padding)
        .frame(width: L.panelWidth)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: L.cornerRadius))
    }
}

private struct LeaderKeyRow: View {
    let mapping: LeaderMapping

    private typealias L = LeaderKeyLayout

    var body: some View {
        HStack(spacing: 12) {
            Text(mapping.key.uppercased())
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(mapping.displayText)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, L.padding)
        .frame(height: L.rowHeight)
    }
}
