import AppKit
import Foundation

/// Manages floating toast alerts for plugin UI feedback.
final class ToastManager {
    nonisolated static let shared = ToastManager()

    private var currentWindow: NSWindow?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    /// Display a floating toast with the given text and duration.
    /// - Parameters:
    ///   - text: The message to display.
    ///   - duration: Time in seconds before auto-dismiss. Default is 2.0.
    /// - Returns: `true` if the toast was shown.
    @discardableResult
    nonisolated func show(text: String, duration: TimeInterval = 2.0) -> Bool {
        DispatchQueue.main.async { [weak self] in
            self?.dismissCurrent()

            let window = self?.createToastWindow(text: text)
            guard let window else { return }
            self?.currentWindow = window
            window.makeKeyAndOrderFront(nil)

            let workItem = DispatchWorkItem { [weak self] in
                self?.dismissCurrent()
            }
            self?.dismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
        }

        return true
    }

    private func dismissCurrent() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentWindow?.orderOut(nil)
        currentWindow = nil
    }

    private func createToastWindow(text: String) -> NSWindow {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 280

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        container.layer?.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        let padding = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let textSize = label.sizeThatFits(
            NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude)
        )
        let width = textSize.width + padding.left + padding.right
        let height = textSize.height + padding.top + padding.bottom

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hasShadow = true

        // Center on screen
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = screenRect.midX - width / 2
            let y = screenRect.midY - height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        return window
    }
}
