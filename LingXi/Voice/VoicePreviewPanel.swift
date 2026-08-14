//
//  VoicePreviewPanel.swift
//  LingXi
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Presenting protocol (test seam)

/// Everything the preview panel needs at open time.
struct VoicePreviewSetup {
    var text: String
    /// Raw ASR text when `text` came from the enhancer, for comparison.
    var original: String?
    /// Ordered mode list; the first nine are reachable via ⌘1-9.
    var modes: [EnhanceMode]
    var currentModeID: String
    /// Flattened provider × model choices for the in-panel LLM dropdown.
    var llmOptions: [LLMSelection]
    var currentLLM: LLMSelection?
    var isCached: Bool
    var history: [VoicePreviewHistoryMenuItem]
}

nonisolated struct VoicePreviewHistoryMenuItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
}

struct VoicePreviewCallbacks {
    var onConfirm: @MainActor (String) -> Void
    var onCopy: @MainActor (String) -> Void
    var onCancel: @MainActor () -> Void
    var onModeSwitch: @MainActor (String) -> Void
    var onModelSwitch: @MainActor (LLMSelection) -> Void
    var onHistorySelect: @MainActor (UUID) -> Void
}

/// Shows the final text before pasting. Return confirms with the (possibly
/// user-edited) current text, ⌘Return copies without pasting, Escape or
/// losing key status cancels, ⌘1-9 switches the enhancement mode.
@MainActor
protocol VoicePreviewPresenting: AnyObject {
    func show(setup: VoicePreviewSetup, callbacks: VoicePreviewCallbacks)
    /// Replaces the displayed result after a re-enhancement or cache hit.
    func update(text: String, original: String?, currentModeID: String, currentLLM: LLMSelection?, isCached: Bool)
    /// Toggles the in-panel progress indicator while re-enhancing.
    func setEnhancing(_ enhancing: Bool)
    func close()
}

// MARK: - Layout

private enum VoicePreviewLayout {
    static let width: CGFloat = 480
    static let height: CGFloat = 210
    static let cornerRadius: CGFloat = 12
    static let bottomOffset: CGFloat = 140
}

// MARK: - Panel manager

@MainActor
final class VoicePreviewPanel: VoicePreviewPresenting {
    private var panel: KeyCapturePanel?
    private var model: VoicePreviewModel?

    func show(setup: VoicePreviewSetup, callbacks: VoicePreviewCallbacks) {
        close()

        let model = VoicePreviewModel(setup: setup)
        model.onModeSwitch = callbacks.onModeSwitch
        model.onModelSwitch = callbacks.onModelSwitch
        model.onHistorySelect = callbacks.onHistorySelect
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
            let current = model?.text ?? setup.text
            self.close()
            callbacks.onConfirm(current)
        }
        newPanel.onCommandReturn = { [weak self, weak model] in
            guard let self else { return }
            let current = model?.text ?? setup.text
            self.close()
            callbacks.onCopy(current)
        }
        newPanel.onEscape = { [weak self] in
            self?.close()
            callbacks.onCancel()
        }
        newPanel.onDigit = { [weak model] digit in
            guard let model, model.modes.indices.contains(digit - 1) else { return }
            callbacks.onModeSwitch(model.modes[digit - 1].id)
        }

        positionPanel(newPanel)
        newPanel.makeKeyAndOrderFront(nil)
        panel = newPanel
    }

    func update(
        text: String,
        original: String?,
        currentModeID: String,
        currentLLM: LLMSelection?,
        isCached: Bool
    ) {
        guard let model else { return }
        model.text = text
        model.original = original
        if original == nil { model.showOriginal = false }
        model.currentModeID = currentModeID
        model.currentLLM = currentLLM
        model.isCached = isCached
        model.isEnhancing = false
    }

    func setEnhancing(_ enhancing: Bool) {
        model?.isEnhancing = enhancing
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        model = nil
        // Detach callbacks first so orderOut's resignKey can't re-enter.
        p.onReturn = nil
        p.onCommandReturn = nil
        p.onEscape = nil
        p.onDigit = nil
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
/// Return/Escape/⌘digits while leaving the previous app active.
private final class KeyCapturePanel: NSPanel {
    var onReturn: (() -> Void)?
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onDigit: ((Int) -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = event.modifierFlags
            switch Int(event.keyCode) {
            case kVK_Return where flags.contains(.command):
                onCommandReturn?()
                return
            case kVK_Return where !flags.contains(.shift):
                onReturn?()
                return
            case kVK_Escape:
                onEscape?()
                return
            default:
                if flags.contains(.command),
                   let chars = event.charactersIgnoringModifiers,
                   let digit = Int(chars), (1...9).contains(digit) {
                    onDigit?(digit)
                    return
                }
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
    var original: String?
    var showOriginal = false
    var modes: [EnhanceMode]
    var currentModeID: String
    var llmOptions: [LLMSelection]
    var currentLLM: LLMSelection?
    var isCached: Bool
    var isEnhancing = false
    var history: [VoicePreviewHistoryMenuItem]

    var onModeSwitch: (@MainActor (String) -> Void)?
    var onModelSwitch: (@MainActor (LLMSelection) -> Void)?
    var onHistorySelect: (@MainActor (UUID) -> Void)?

    init(setup: VoicePreviewSetup) {
        text = setup.text
        original = setup.original
        modes = setup.modes
        currentModeID = setup.currentModeID
        llmOptions = setup.llmOptions
        currentLLM = setup.currentLLM
        isCached = setup.isCached
        history = setup.history
    }

    var currentModeLabel: String {
        modes.first { $0.id == currentModeID }?.label ?? currentModeID
    }
}

private struct VoicePreviewContent: View {
    @Bindable var model: VoicePreviewModel
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            toolbar

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
                Text("⏎ Paste · ⌘⏎ Copy · Esc Cancel")
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

    private var toolbar: some View {
        HStack(spacing: 8) {
            if !model.modes.isEmpty {
                Menu {
                    ForEach(Array(model.modes.enumerated()), id: \.element.id) { index, mode in
                        Button {
                            model.onModeSwitch?(mode.id)
                        } label: {
                            if index < 9 {
                                Text("\(mode.label)  ⌘\(index + 1)")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                } label: {
                    Label(model.currentModeLabel, systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if !model.llmOptions.isEmpty {
                Menu {
                    ForEach(model.llmOptions, id: \.self) { option in
                        Button("\(option.provider) · \(option.model)") {
                            model.onModelSwitch?(option)
                        }
                    }
                } label: {
                    Label(model.currentLLM?.model ?? "model", systemImage: "cpu")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if model.isEnhancing {
                ProgressView()
                    .controlSize(.small)
            } else if model.isCached {
                Text("cached")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }

            Spacer()

            if !model.history.isEmpty {
                Menu {
                    ForEach(model.history) { item in
                        Button(item.title) {
                            model.onHistorySelect?(item.id)
                        }
                    }
                } label: {
                    Image(systemName: "clock")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}
