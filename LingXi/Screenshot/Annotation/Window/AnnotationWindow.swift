//
//  AnnotationWindow.swift
//  LingXi
//

import AppKit

final class AnnotationWindow: NSWindow {
    weak var annotationState: AnnotationState?

    private enum KeyCode {
        static let escape: UInt16 = 53
        static let `return`: UInt16 = 36
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        animationBehavior = .documentWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - Keyboard shortcuts

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let state = annotationState else {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        if key == "z" && flags == .command {
            state.undo()
            return true
        }
        if key == "z" && flags == [.command, .shift] {
            state.redo()
            return true
        }

        if key == "c" && flags == .command {
            state.onCopy?()
            return true
        }

        if key == "s" && flags == .command {
            state.onSave?()
            return true
        }

        if event.keyCode == KeyCode.escape && flags.isEmpty {
            if firstResponder is NSTextView || firstResponder is NSTextField {
                state.onCancelTextEditing?()
                makeFirstResponder(nil)
                return true
            }
            if state.selectedAnnotationId != nil {
                state.selectedAnnotationId = nil
                return true
            }
            state.onClose?()
            return true
        }

        if event.keyCode == KeyCode.return && flags.isEmpty {
            state.onCopy?()
            return true
        }

        if event.keyCode == KeyCode.delete || event.keyCode == KeyCode.forwardDelete {
            if (flags.isEmpty || flags == .function) && state.selectedAnnotationId != nil {
                state.deleteSelected()
                return true
            }
        }

        if flags.isEmpty, key.count == 1, let char = key.first {
            for tool in AnnotationTool.allCases where tool.shortcutKey == char {
                state.selectedTool = tool
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }
}
