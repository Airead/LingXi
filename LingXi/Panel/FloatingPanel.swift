//
//  FloatingPanel.swift
//  LingXi
//
//  Created by fanrenhao on 2026/4/2.
//

import AppKit

final class FloatingPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onReturn: ((Set<ActionModifier>) -> Void)?
    var onModifiersChanged: ((Set<ActionModifier>) -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch event.keyCode {
            case 53: // Esc
                onDismiss?()
                return
            case 126: // ↑
                onArrowUp?()
                return
            case 125: // ↓
                onArrowDown?()
                return
            case 36: // Return
                onReturn?(Self.activeModifiers(from: event.modifierFlags))
                return
            default:
                break
            }
        }
        if event.type == .flagsChanged {
            onModifiersChanged?(Self.activeModifiers(from: event.modifierFlags))
        }
        super.sendEvent(event)
    }

    private static func activeModifiers(from flags: NSEvent.ModifierFlags) -> Set<ActionModifier> {
        var result = Set<ActionModifier>()
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    override func resignKey() {
        super.resignKey()
        if isVisible {
            onDismiss?()
        }
    }
}
