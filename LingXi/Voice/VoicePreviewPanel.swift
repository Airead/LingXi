//
//  VoicePreviewPanel.swift
//  LingXi
//

import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Presenting protocol (test seam)

/// Everything the preview panel needs at open time. `text` is the initial
/// final text (enhanced result, or the ASR text when no enhancement ran);
/// `original` carries the raw ASR text only when `text` came from the
/// enhancer.
struct VoicePreviewSetup {
    var text: String
    var original: String?
    /// Info line next to the ASR section title, e.g. "apple · 3.2s".
    var asrInfo: String
    /// The panel opened while transcription is still running; the ASR area
    /// shows a progress state until `setASRResult`/`setASRFailed` arrives.
    var isTranscribing = false
    /// Apple Speech plus every provider × model pair, for the in-panel
    /// re-transcribe dropdown.
    var asrOptions: [ASRSelection] = []
    var currentASR: ASRSelection = .apple
    /// Ordered mode list; the panel prepends an "Off" segment, so ⌘1 is Off
    /// and ⌘2 is the first mode.
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
    var onASRSwitch: @MainActor (ASRSelection) -> Void
    var onHistorySelect: @MainActor (UUID) -> Void
}

/// Shows the transcription, the enhancement result and an editable final
/// text before pasting. Return confirms with the final text, ⌘Return copies
/// without pasting, Escape or losing key status cancels, ⌘1-9 switches the
/// enhancement mode (⌘1 = Off).
@MainActor
protocol VoicePreviewPresenting: AnyObject {
    func show(setup: VoicePreviewSetup, callbacks: VoicePreviewCallbacks)
    /// Fills the ASR area once a pending transcription finishes; the final
    /// text follows unless the user already edited it.
    func setASRResult(text: String, asrInfo: String)
    /// Shows a transcription failure in the ASR area; the panel stays open
    /// so the user can dismiss it or type a final text manually.
    func setASRFailed(message: String)
    /// Provides the recording as WAV once converted; enables the playback
    /// and save controls in the ASR section.
    func setAudioAvailable(wavData: Data)
    /// Puts the ASR area back into a progress state while an in-panel model
    /// switch re-transcribes the retained audio.
    func setASRTranscribing(info: String)
    /// Replaces the displayed result after a re-enhancement, cache hit or
    /// degrade. `original` non-nil means `text` is an enhancement result;
    /// nil means no enhancement (mode off or reverted to the ASR text).
    func update(text: String, original: String?, currentModeID: String, currentLLM: LLMSelection?, isCached: Bool)
    /// Toggles the in-panel progress indicator while re-enhancing. Turning
    /// it on clears the previous result so streamed deltas build up fresh.
    func setEnhancing(_ enhancing: Bool)
    /// Appends one streamed chunk to the enhance area.
    func appendEnhanceDelta(_ delta: String)
    /// The full system prompt behind the displayed enhancement (mode prompt
    /// plus history injection); nil hides/disables the prompt viewer.
    func setSystemPrompt(_ prompt: String?)
    /// Token usage of the displayed enhancement; nil hides the token info.
    func setTokenUsage(_ usage: TokenUsage?)
    func close()
}

// MARK: - Layout

private enum VoicePreviewLayout {
    static let width: CGFloat = 640
    /// Golden-ratio height, matching WenZi's result window.
    static let fullHeight: CGFloat = 396
    /// Height without the mode segment and enhance section.
    static let compactHeight: CGFloat = 280
    static let cornerRadius: CGFloat = 12
    static let readOnlyAreaHeight: CGFloat = 74
}

// MARK: - Panel manager

@MainActor
final class VoicePreviewPanel: VoicePreviewPresenting {
    private var panel: KeyCapturePanel?
    private var model: VoicePreviewModel?
    private var player: AVAudioPlayer?
    private var playbackDelegate: PlaybackDelegate?

    func show(setup: VoicePreviewSetup, callbacks: VoicePreviewCallbacks) {
        close()

        let model = VoicePreviewModel(setup: setup)
        self.model = model

        let height = setup.modes.isEmpty
            ? VoicePreviewLayout.compactHeight
            : VoicePreviewLayout.fullHeight
        let newPanel = KeyCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: VoicePreviewLayout.width, height: height),
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

        let confirm: @MainActor () -> Void = { [weak self, weak model] in
            guard let self else { return }
            let current = model?.finalText ?? setup.text
            self.close()
            callbacks.onConfirm(current)
        }
        let copy: @MainActor () -> Void = { [weak self, weak model] in
            guard let self else { return }
            let current = model?.finalText ?? setup.text
            self.close()
            callbacks.onCopy(current)
        }
        let cancel: @MainActor () -> Void = { [weak self] in
            self?.close()
            callbacks.onCancel()
        }

        newPanel.onReturn = confirm
        newPanel.onCommandReturn = copy
        newPanel.onEscape = cancel
        newPanel.onDigit = { [weak model] digit in
            guard let model else { return }
            let segments = model.segments
            guard segments.indices.contains(digit - 1) else { return }
            model.userEdited = false
            callbacks.onModeSwitch(segments[digit - 1].id)
        }
        newPanel.onCommandFlagChanged = { [weak model] held in
            model?.cmdHeld = held
        }
        // A file dialog (or popover) steals key status; don't treat that
        // as clicking away from the panel.
        newPanel.shouldCancelOnResign = { [weak model] in
            !(model?.suppressesCancelOnResign ?? false)
        }

        model.onConfirmTap = confirm
        model.onCopyTap = copy
        model.onCancelTap = cancel
        model.onModeSwitch = callbacks.onModeSwitch
        model.onModelSwitch = callbacks.onModelSwitch
        model.onASRSwitch = callbacks.onASRSwitch
        model.onHistorySelect = callbacks.onHistorySelect
        model.onPlayToggle = { [weak self] in self?.togglePlayback() }
        model.onSaveAudio = { [weak self] in self?.saveAudio() }
        // The popover took key status; restore it so Return/Esc keep working.
        model.onPromptPopoverDismissed = { [weak self] in
            self?.panel?.makeKeyAndOrderFront(nil)
        }

        positionPanel(newPanel)
        newPanel.makeKeyAndOrderFront(nil)
        panel = newPanel
    }

    func setASRResult(text: String, asrInfo: String) {
        model?.applyASRResult(text: text, asrInfo: asrInfo)
    }

    func setASRFailed(message: String) {
        model?.applyASRFailure(message: message)
    }

    func setAudioAvailable(wavData: Data) {
        model?.audioData = wavData
    }

    func setASRTranscribing(info: String) {
        model?.applyASRTranscribing(info: info)
    }

    func update(
        text: String,
        original: String?,
        currentModeID: String,
        currentLLM: LLMSelection?,
        isCached: Bool
    ) {
        model?.apply(
            text: text,
            original: original,
            currentModeID: currentModeID,
            currentLLM: currentLLM,
            isCached: isCached
        )
    }

    func setEnhancing(_ enhancing: Bool) {
        if enhancing {
            model?.beginEnhancingDisplay()
        } else {
            model?.isEnhancing = false
        }
    }

    func appendEnhanceDelta(_ delta: String) {
        model?.appendEnhanceDelta(delta)
    }

    func setSystemPrompt(_ prompt: String?) {
        model?.systemPrompt = prompt
    }

    func setTokenUsage(_ usage: TokenUsage?) {
        model?.tokenUsage = usage
    }

    func close() {
        player?.stop()
        player = nil
        playbackDelegate = nil
        guard let p = panel else { return }
        panel = nil
        model = nil
        // Detach callbacks first so orderOut's resignKey can't re-enter.
        p.onReturn = nil
        p.onCommandReturn = nil
        p.onEscape = nil
        p.onDigit = nil
        p.onCommandFlagChanged = nil
        p.orderOut(nil)
    }

    // MARK: Audio playback & save

    private func togglePlayback() {
        guard let model else { return }
        if let player, player.isPlaying {
            player.pause()
            model.isPlaying = false
            return
        }
        if player == nil {
            guard let data = model.audioData,
                  let newPlayer = try? AVAudioPlayer(data: data) else {
                DebugLog.log("[Voice] preview playback unavailable")
                return
            }
            let delegate = PlaybackDelegate { [weak self] in
                self?.model?.isPlaying = false
            }
            newPlayer.delegate = delegate
            playbackDelegate = delegate
            player = newPlayer
        }
        player?.play()
        model.isPlaying = true
    }

    private func saveAudio() {
        guard let model, let data = model.audioData else { return }
        model.savePanelShown = true
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.wav]
        savePanel.nameFieldStringValue =
            "LingXi-Recording-\(Self.saveNameFormatter.string(from: Date())).wav"
        NSApp.activate(ignoringOtherApps: true)
        savePanel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.model?.savePanelShown = false
                // Restore key status so Return/Esc keep working.
                self.panel?.makeKeyAndOrderFront(nil)
                guard response == .OK, let url = savePanel.url else { return }
                do {
                    try data.write(to: url)
                    DebugLog.log("[Voice] recording saved to \(url.path)")
                } catch {
                    DebugLog.log("[Voice] failed to save recording: \(error)")
                }
            }
        }
    }

    private static let saveNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let x = sf.midX - panel.frame.width / 2
        let y = sf.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: max(sf.minY, min(y, sf.maxY - panel.frame.height))))
    }
}

/// Hops the finish callback back to the MainActor; AVAudioPlayer calls its
/// delegate on an arbitrary thread.
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let onFinish = onFinish
        Task { @MainActor in onFinish() }
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
    var onCommandFlagChanged: ((Bool) -> Void)?
    /// Returning false suppresses the cancel-on-resign behavior while a
    /// child window (save dialog, popover) holds key status.
    var shouldCancelOnResign: (() -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            onCommandFlagChanged?(event.modifierFlags.contains(.command))
        }
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
        if isVisible, shouldCancelOnResign?() ?? true {
            onEscape?()
        }
    }
}

// MARK: - Model

@Observable
@MainActor
final class VoicePreviewModel {
    var asrText: String
    var asrInfo: String
    /// Transcription still running in the background.
    var isTranscribing: Bool
    /// Transcription failed or came back empty; shown in the ASR area.
    var asrFailureMessage: String?
    /// The recording as WAV, once converted; nil for recalled entries.
    var audioData: Data?
    var isPlaying = false
    /// A modal save dialog is open; suppresses cancel-on-resign.
    var savePanelShown = false
    /// System prompt of the displayed enhancement; nil disables the viewer.
    var systemPrompt: String?
    /// Token usage of the displayed enhancement; nil hides the info line.
    var tokenUsage: TokenUsage?
    var promptPopoverShown = false

    /// Key status is expected to move to a child window (save dialog,
    /// popover); losing it must not dismiss the panel.
    var suppressesCancelOnResign: Bool {
        savePanelShown || promptPopoverShown
    }
    var enhancedText: String?
    var finalText: String
    /// Set when the user types in the final area; blocks programmatic
    /// overwrites of the final text until the next mode/model switch.
    var userEdited = false
    var modes: [EnhanceMode]
    var currentModeID: String
    var llmOptions: [LLMSelection]
    var currentLLM: LLMSelection?
    var asrOptions: [ASRSelection]
    var currentASR: ASRSelection
    var isCached: Bool
    var isEnhancing = false
    /// Command key is held: the confirm button becomes "Copy".
    var cmdHeld = false
    var history: [VoicePreviewHistoryMenuItem]

    var onModeSwitch: (@MainActor (String) -> Void)?
    var onModelSwitch: (@MainActor (LLMSelection) -> Void)?
    var onASRSwitch: (@MainActor (ASRSelection) -> Void)?
    var onHistorySelect: (@MainActor (UUID) -> Void)?
    var onPlayToggle: (@MainActor () -> Void)?
    var onSaveAudio: (@MainActor () -> Void)?
    var onPromptPopoverDismissed: (@MainActor () -> Void)?
    var onConfirmTap: (@MainActor () -> Void)?
    var onCopyTap: (@MainActor () -> Void)?
    var onCancelTap: (@MainActor () -> Void)?

    init(setup: VoicePreviewSetup) {
        asrText = setup.original ?? setup.text
        asrInfo = setup.asrInfo
        isTranscribing = setup.isTranscribing
        enhancedText = setup.original != nil ? setup.text : nil
        finalText = setup.text
        modes = setup.modes
        currentModeID = setup.currentModeID
        llmOptions = setup.llmOptions
        currentLLM = setup.currentLLM
        asrOptions = setup.asrOptions
        currentASR = setup.currentASR
        isCached = setup.isCached
        history = setup.history
    }

    /// Segment items for the mode bar: Off first, then the mode files.
    /// ⌘1-9 indexes into this list.
    var segments: [(id: String, label: String)] {
        [(EnhanceMode.offModeID, "Off")] + modes.map { ($0.id, $0.label) }
    }

    enum EnhanceState: Equatable {
        case off
        /// Transcription not finished (or failed): nothing to enhance yet.
        case pending
        case enhancing
        case result(cached: Bool)
        /// Enhancement failed or timed out; the ASR text is shown instead.
        case reverted
    }

    var enhanceState: EnhanceState {
        if isEnhancing { return .enhancing }
        if enhancedText != nil { return .result(cached: isCached) }
        if currentModeID == EnhanceMode.offModeID { return .off }
        if isTranscribing || asrFailureMessage != nil || asrText.isEmpty { return .pending }
        return .reverted
    }

    /// Fills the ASR area after a background transcription completes.
    func applyASRResult(text: String, asrInfo: String) {
        asrText = text
        self.asrInfo = asrInfo
        isTranscribing = false
        asrFailureMessage = nil
        if !userEdited {
            finalText = text
        }
    }

    func applyASRFailure(message: String) {
        isTranscribing = false
        asrFailureMessage = message
    }

    /// An in-panel ASR model switch re-runs transcription: back to progress.
    func applyASRTranscribing(info: String) {
        isTranscribing = true
        asrInfo = info
        asrFailureMessage = nil
    }

    /// Enhancement starts: clear the previous result so streamed deltas
    /// build up from scratch (WenZi-style live display).
    func beginEnhancingDisplay() {
        enhancedText = nil
        tokenUsage = nil
        isEnhancing = true
    }

    /// Appends a streamed chunk; late deltas after completion or
    /// cancellation are dropped.
    func appendEnhanceDelta(_ delta: String) {
        guard isEnhancing else { return }
        enhancedText = (enhancedText ?? "") + delta
    }

    /// Applies a re-enhancement result, cache hit or degrade outcome. The
    /// final text follows the result unless the user already edited it.
    func apply(
        text: String,
        original: String?,
        currentModeID: String,
        currentLLM: LLMSelection?,
        isCached: Bool
    ) {
        enhancedText = original != nil ? text : nil
        self.currentModeID = currentModeID
        self.currentLLM = currentLLM
        self.isCached = isCached
        isEnhancing = false
        if !userEdited {
            finalText = text
        }
    }
}

// MARK: - Content view

private struct VoicePreviewContent: View {
    @Bindable var model: VoicePreviewModel
    @FocusState private var isFinalFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            asrSection
            if !model.modes.isEmpty {
                segmentBar
                enhanceSection
            }
            finalSection
            Divider()
            buttonBar
        }
        .padding(12)
        .frame(
            width: VoicePreviewLayout.width,
            height: model.modes.isEmpty
                ? VoicePreviewLayout.compactHeight
                : VoicePreviewLayout.fullHeight
        )
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: VoicePreviewLayout.cornerRadius))
        .onAppear { isFinalFocused = true }
    }

    // MARK: ASR

    private var asrSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("ASR")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.asrInfo)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if !model.asrOptions.isEmpty && model.audioData != nil {
                    Menu {
                        ForEach(model.asrOptions, id: \.self) { option in
                            Button {
                                model.userEdited = false
                                model.currentASR = option
                                model.onASRSwitch?(option)
                            } label: {
                                if option == model.currentASR {
                                    Label(asrOptionLabel(option), systemImage: "checkmark")
                                } else {
                                    Text(asrOptionLabel(option))
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.isTranscribing)
                    .help("Re-transcribe with another model")
                }
                if model.audioData != nil {
                    Button {
                        model.onPlayToggle?()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Play recording")
                    Button {
                        model.onSaveAudio?()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Save recording as WAV")
                }
                Spacer()
            }
            readOnlyContainer {
                if model.isTranscribing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                } else if let failure = model.asrFailureMessage {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(6)
                } else {
                    readOnlyText(model.asrText)
                }
            }
        }
    }

    // MARK: Mode segment

    private var segmentBar: some View {
        Picker("Mode", selection: Binding(
            get: { model.currentModeID },
            set: { newID in
                // Switching modes means the user wants that result: allow
                // the final text to follow it again.
                model.userEdited = false
                model.currentModeID = newID
                model.onModeSwitch?(newID)
            }
        )) {
            ForEach(model.segments, id: \.id) { segment in
                Text(segment.label).tag(segment.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: Enhance

    private var enhanceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("AI Enhance")
                    .font(.system(size: 12, weight: .semibold))
                if !model.llmOptions.isEmpty {
                    Menu {
                        ForEach(model.llmOptions, id: \.self) { option in
                            Button("\(option.provider) · \(option.model)") {
                                model.userEdited = false
                                // Optimistic label update; the controller's
                                // next update() confirms or corrects it.
                                model.currentLLM = option
                                model.onModelSwitch?(option)
                            }
                        }
                    } label: {
                        Text(llmLabel)
                            .font(.system(size: 10))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button {
                    model.promptPopoverShown = true
                } label: {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.systemPrompt == nil)
                .opacity(model.systemPrompt == nil ? 0.3 : 1)
                .help("Show the system prompt used for this enhancement")
                .popover(isPresented: $model.promptPopoverShown) {
                    ScrollView {
                        Text(model.systemPrompt ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(width: 420, height: 260)
                    .onDisappear { model.onPromptPopoverDismissed?() }
                }
                enhanceStateView
                if let tokens = model.tokenUsage?.displayText {
                    Text(tokens)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            readOnlyContainer(background: Color.accentColor.opacity(0.06)) {
                readOnlyText(model.enhancedText ?? "")
            }
        }
    }

    private var llmLabel: String {
        guard let llm = model.currentLLM else { return "model" }
        return "\(llm.provider) · \(llm.model)"
    }

    private func asrOptionLabel(_ option: ASRSelection) -> String {
        switch option {
        case .apple: "apple"
        case .remote(let provider, let model): "\(provider) · \(model)"
        }
    }

    @ViewBuilder
    private var enhanceStateView: some View {
        switch model.enhanceState {
        case .off:
            stateText("Not enabled")
        case .pending:
            EmptyView()
        case .enhancing:
            ProgressView()
                .controlSize(.small)
            stateText("Enhancing…")
        case .result(let cached):
            if cached {
                Text("cached")
                    .font(.system(size: 9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
        case .reverted:
            stateText("Failed, using ASR text")
                .foregroundStyle(.orange)
        }
    }

    private func stateText(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    // MARK: Final

    private var finalSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Final")
                .font(.system(size: 12, weight: .semibold))
            TextEditor(text: Binding(
                get: { model.finalText },
                set: { newValue in
                    // Only user typing goes through this binding;
                    // programmatic updates assign model.finalText directly.
                    model.finalText = newValue
                    model.userEdited = true
                }
            ))
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .focused($isFinalFocused)
        }
    }

    // MARK: Buttons

    private var buttonBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.history) { item in
                    Button(item.title) {
                        model.onHistorySelect?(item.id)
                    }
                }
            } label: {
                Text("History (\(model.history.count))")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.history.isEmpty)

            Text("⏎ Paste · ⌘⏎ Copy · Esc Cancel · ⌘1-9 Mode")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") { model.onCancelTap?() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(model.cmdHeld ? "Copy" : "Confirm") {
                if model.cmdHeld {
                    model.onCopyTap?()
                } else {
                    model.onConfirmTap?()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: Helpers

    private func readOnlyContainer(
        background: Color = Color(nsColor: .quaternarySystemFill),
        @ViewBuilder content: () -> some View
    ) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: VoicePreviewLayout.readOnlyAreaHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(background)
        )
    }

    private func readOnlyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
    }
}
