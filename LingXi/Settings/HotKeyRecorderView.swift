//
//  HotKeyRecorderView.swift
//  LingXi
//

import Carbon
import SwiftUI

struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    var allowEmpty: Bool = false

    func makeNSView(context: Context) -> HotKeyRecorderNSView {
        let view = HotKeyRecorderNSView()
        view.keyCode = keyCode
        view.modifiers = modifiers
        view.allowEmpty = allowEmpty
        view.onChange = { newKeyCode, newModifiers in
            keyCode = newKeyCode
            modifiers = newModifiers
        }
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderNSView, context: Context) {
        guard nsView.keyCode != keyCode || nsView.modifiers != modifiers else { return }
        nsView.keyCode = keyCode
        nsView.modifiers = modifiers
        nsView.needsDisplay = true
    }
}

final class HotKeyRecorderNSView: NSView {
    var keyCode: UInt32 = AppSettings.defaultHotKeyKeyCode
    var modifiers: UInt32 = AppSettings.defaultHotKeyModifiers
    var allowEmpty: Bool = false
    var onChange: ((UInt32, UInt32) -> Void)?

    private var isRecording = false
    nonisolated(unsafe) private var localMonitor: Any?
    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    private var showClearButton: Bool {
        allowEmpty && AppSettings.isHotKeySet(keyCode: keyCode, modifiers: modifiers) && isHovering && !isRecording
    }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverTrackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        } else {
            NSColor.controlBackgroundColor.setFill()
        }
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()

        let text: String
        let textColor: NSColor
        if isRecording {
            text = "Type shortcut..."
            textColor = .secondaryLabelColor
        } else if !AppSettings.isHotKeySet(keyCode: keyCode, modifiers: modifiers) && allowEmpty {
            text = "Record Shortcut"
            textColor = .tertiaryLabelColor
        } else {
            text = AppSettings.displayString(keyCode: keyCode, modifiers: modifiers)
            textColor = .labelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: textColor,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let size = attrString.size()

        let textX: CGFloat
        if showClearButton {
            textX = (bounds.width - clearButtonSize - 4 - size.width) / 2
        } else {
            textX = (bounds.width - size.width) / 2
        }
        let point = NSPoint(x: textX, y: (bounds.height - size.height) / 2)
        attrString.draw(at: point)

        if showClearButton {
            drawClearButton()
        }
    }

    // MARK: - Clear button

    private let clearButtonSize: CGFloat = 16

    private var clearButtonRect: NSRect {
        NSRect(
            x: bounds.width - clearButtonSize - 8,
            y: (bounds.height - clearButtonSize) / 2,
            width: clearButtonSize,
            height: clearButtonSize
        )
    }

    private static let clearButtonBaseImage: NSImage? =
        NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")

    private func drawClearButton() {
        guard let base = Self.clearButtonBaseImage else { return }
        let config = NSImage.SymbolConfiguration(pointSize: clearButtonSize, weight: .regular)
            .applying(.init(hierarchicalColor: .tertiaryLabelColor))
        let styled = base.withSymbolConfiguration(config) ?? base
        styled.draw(in: clearButtonRect)
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if showClearButton && clearButtonRect.contains(localPoint) {
            clearHotKey()
            return
        }
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func clearHotKey() {
        keyCode = 0
        modifiers = 0
        onChange?(0, 0)
        needsDisplay = true
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        needsDisplay = true
        window?.makeFirstResponder(self)

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        needsDisplay = true
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let flags = event.modifierFlags
        let newKeyCode = UInt32(event.keyCode)

        if newKeyCode == UInt32(kVK_Escape) && !flags.contains(.command) && !flags.contains(.option) {
            stopRecording()
            return
        }

        if allowEmpty && newKeyCode == UInt32(kVK_Delete) && !flags.contains(.command) && !flags.contains(.option) {
            clearHotKey()
            stopRecording()
            return
        }

        var carbonModifiers: UInt32 = 0
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }

        guard carbonModifiers != 0 else { return }

        keyCode = newKeyCode
        modifiers = carbonModifiers
        onChange?(newKeyCode, carbonModifiers)
        stopRecording()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return super.resignFirstResponder()
    }

    deinit {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
