//
//  FloatingPanel.swift
//  LingXi
//
//  Created by fanrenhao on 2026/4/2.
//

import AppKit
import Carbon.HIToolbox

final class FloatingPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onReturn: ((Set<ActionModifier>) -> Void)?
    var onDelete: (() -> Void)?
    var onModifiersChanged: ((Set<ActionModifier>) -> Void)?
    var onCommandComma: (() -> Void)?
    var onCommandN: (() -> Void)?
    var onNumberKey: ((Int) -> Void)?
    var onTab: (() -> Void)?

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

    private func findFirstTextField(in view: NSView?) -> NSTextField? {
        guard let view = view else { return nil }
        if let textField = view as? NSTextField {
            return textField
        }
        for subview in view.subviews {
            if let textField = findFirstTextField(in: subview) {
                return textField
            }
        }
        return nil
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // Manually route standard editing shortcuts to the text field's
            // field editor so they work even inside a SwiftUI NSHostingView.
            if event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers?.lowercased() {
                if let textField = findFirstTextField(in: contentView),
                   let editor = textField.currentEditor() {
                    switch chars {
                    case "a": editor.selectAll(self); return
                    case "c": editor.copy(self); return
                    case "v": editor.paste(self); return
                    case "x": editor.cut(self); return
                    default: break
                    }
                }
            }

            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                onCommandComma?()
                return
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "n" {
                onCommandN?()
                return
            }
            if event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars), (1...9).contains(digit) {
                onNumberKey?(digit - 1)
                return
            }
            if event.modifierFlags.contains(.command), Int(event.keyCode) == kVK_Delete {
                onDelete?()
                return
            }
            switch Int(event.keyCode) {
            case kVK_Escape:
                onDismiss?()
                return
            case kVK_UpArrow:
                onArrowUp?()
                return
            case kVK_DownArrow:
                onArrowDown?()
                return
            case kVK_Return:
                onReturn?(Self.activeModifiers(from: event.modifierFlags))
                return
            case kVK_Tab:
                onTab?()
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
