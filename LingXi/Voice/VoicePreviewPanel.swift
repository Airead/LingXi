//
//  VoicePreviewPanel.swift
//  LingXi
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Presenting protocol (test seam)

/// Shows the final text before pasting; Return confirms with the (possibly
/// user-edited) current text, Escape or losing key status cancels.
@MainActor
protocol VoicePreviewPresenting: AnyObject {
    func show(
        text: String,
        original: String?,
        onConfirm: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    )
    func close()
}

// MARK: - Layout

private enum VoicePreviewLayout {
    static let width: CGFloat = 480
    static let height: CGFloat = 180
    static let cornerRadius: CGFloat = 12
    static let bottomOffset: CGFloat = 140
}

// MARK: - Panel manager

@MainActor
final class VoicePreviewPanel: VoicePreviewPresenting {
    private var panel: KeyCapturePanel?
    private var model: VoicePreviewModel?

    func show(
        text: String,
        original: String?,
        onConfirm: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        close()

        let model = VoicePreviewModel(text: text, original: original)
        self.model = model

        let newPanel = KeyCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: VoicePreviewLayout.width, height: VoicePreviewLayout.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.isMovableByWindowBackground = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = NSHostingView(rootView: VoicePreviewContent(model: model))
        newPanel.onReturn = { [weak self, weak model] in
            guard let self else { return }
            let current = model?.text ?? text
            self.close()
            onConfirm(current)
        }
        newPanel.onEscape = { [weak self] in
            self?.close()
            onCancel()
        }

        positionPanel(newPanel)
        newPanel.makeKeyAndOrderFront(nil)
        panel = newPanel
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        model = nil
        // Detach callbacks first so orderOut's resignKey can't re-enter.
        p.onReturn = nil
        p.onEscape = nil
        p.orderOut(nil)
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let x = sf.midX - panel.frame.width / 2
        let y = sf.minY + VoicePreviewLayout.bottomOffset
        panel.setFrameOrigin(NSPoint(x: x, y: max(sf.minY, min(y, sf.maxY - panel.frame.height))))
    }
}

// MARK: - Key-capturing panel

/// Borderless non-activating panel that can become key to receive
/// Return/Escape while leaving the previous app active.
private final class KeyCapturePanel: NSPanel {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch Int(event.keyCode) {
            case kVK_Return where !event.modifierFlags.contains(.shift):
                onReturn?()
                return
            case kVK_Escape:
                onEscape?()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        // Clicking elsewhere dismisses the preview (discard).
        if isVisible {
            onEscape?()
        }
    }
}

// MARK: - Model & content

@Observable
@MainActor
final class VoicePreviewModel {
    var text: String
    let original: String?
    var showOriginal = false

    init(text: String, original: String?) {
        self.text = text
        self.original = original
    }
}

private struct VoicePreviewContent: View {
    @Bindable var model: VoicePreviewModel
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if model.showOriginal, let original = model.original {
                ScrollView {
                    Text(original)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
            } else {
                TextEditor(text: $model.text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($isEditorFocused)
            }

            HStack {
                if model.original != nil {
                    Toggle("Show original", isOn: $model.showOriginal)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("⏎ Paste · Esc Cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: VoicePreviewLayout.width, height: VoicePreviewLayout.height)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: VoicePreviewLayout.cornerRadius))
        .onAppear { isEditorFocused = true }
    }
}
