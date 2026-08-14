//
//  VoiceInputController.swift
//  LingXi
//

import AppKit
import AVFoundation
import Foundation

/// Timing knobs, injectable for tests.
struct VoiceInputTiming: Sendable {
    /// Presses shorter than this are treated as accidental and cancelled.
    var minHold: Duration = .milliseconds(250)
    /// Recording is force-stopped (and transcribed) after this duration.
    var maxRecording: Duration = .seconds(120)
    /// Watchdog for a transcription that never completes.
    var transcribeTimeout: Duration = .seconds(30)
    /// Watchdog for an enhancement request; on timeout the original
    /// transcription is used (degrade, not discard).
    var enhanceTimeout: Duration = .seconds(15)
}

/// Push-to-talk state machine: hold Fn → record → release → transcribe → paste.
///
/// Concurrency model: every state transition happens on the MainActor — the
/// Fn monitor, audio engine startup, recognition callbacks and timers all
/// hop back here before touching state, so transitions are serialized by
/// construction. Async completions carry the `generation` captured at
/// session start; a mismatch means the session was superseded or cancelled,
/// and the callback may only clean up after itself, never touch state.
@MainActor
final class VoiceInputController {
    private let settings: AppSettings
    private let activityModel: VoiceActivityModel
    private let recorder: any AudioRecording
    private let transcriberFactory: (AppSettings) -> any SpeechTranscriber
    private let enhancerFactory: (AppSettings) -> any TextEnhancer
    private let pasteAction: (String) -> Void
    private let ensureMicrophonePermission: @Sendable () async throws -> Void
    private let frontmostAppProvider: () -> NSRunningApplication?
    private let timing: VoiceInputTiming
    private let clock = ContinuousClock()

    private var monitor: VoiceKeyMonitor?
    private var generation: UInt64 = 0
    private var state: State = .idle
    private var maxDurationTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?

    private var injectedPreviewPresenter: (any VoicePreviewPresenting)?
    private lazy var previewPresenter: any VoicePreviewPresenting =
        injectedPreviewPresenter ?? VoicePreviewPanel()

    private var injectedHUDPresenter: (any VoiceHUDPresenting)?
    private lazy var hudPresenter: any VoiceHUDPresenting =
        injectedHUDPresenter ?? VoiceHUDPanel(activityModel: activityModel)
    private var hudShown = false

    private enum State {
        case idle
        case starting(StartingContext)
        case recording(RecordingContext)
        case transcribing(session: any SpeechTranscriptionSession)
        case enhancing(original: String, task: Task<Void, Never>)
        case previewing
    }

    private struct StartingContext {
        let pressedAt: ContinuousClock.Instant
        var stopRequested = false
        var cancelled = false
    }

    private struct RecordingContext {
        let session: any SpeechTranscriptionSession
        let pressedAt: ContinuousClock.Instant
    }

    init(
        settings: AppSettings,
        activityModel: VoiceActivityModel,
        recorder: (any AudioRecording)? = nil,
        transcriberFactory: ((AppSettings) -> any SpeechTranscriber)? = nil,
        enhancerFactory: ((AppSettings) -> any TextEnhancer)? = nil,
        pasteAction: ((String) -> Void)? = nil,
        ensureMicrophonePermission: (@Sendable () async throws -> Void)? = nil,
        previewPresenter: (any VoicePreviewPresenting)? = nil,
        hudPresenter: (any VoiceHUDPresenting)? = nil,
        frontmostAppProvider: (() -> NSRunningApplication?)? = nil,
        timing: VoiceInputTiming = VoiceInputTiming()
    ) {
        self.settings = settings
        self.activityModel = activityModel
        self.recorder = recorder ?? VoiceAudioRecorder()
        self.transcriberFactory = transcriberFactory ?? Self.defaultTranscriberFactory
        self.enhancerFactory = enhancerFactory ?? Self.defaultEnhancerFactory
        self.pasteAction = pasteAction ?? Self.defaultPasteAction
        self.ensureMicrophonePermission = ensureMicrophonePermission ?? Self.defaultMicrophonePermission
        self.injectedPreviewPresenter = previewPresenter
        self.injectedHUDPresenter = hudPresenter
        self.frontmostAppProvider = frontmostAppProvider ?? { NSWorkspace.shared.frontmostApplication }
        self.timing = timing
    }

    // MARK: - Lifecycle

    /// Starts or stops the Fn monitor according to current settings.
    /// Call once after assembly and again whenever voice settings change.
    func applySettings() {
        if settings.voiceInputEnabled {
            guard monitor == nil else { return }
            let m = VoiceKeyMonitor()
            m.delegate = self
            m.start()
            monitor = m
            DebugLog.log("[Voice] Fn monitor started")
        } else {
            guard let m = monitor else { return }
            monitor = nil
            m.stop()
            abortActiveSession(reason: "voice input disabled")
            DebugLog.log("[Voice] Fn monitor stopped")
        }
    }

    // MARK: - Events (all MainActor)

    func fnDown() {
        guard settings.voiceInputEnabled else { return }
        switch state {
        case .idle:
            break
        case .previewing:
            // A new press discards the pending preview and starts fresh.
            DebugLog.log("[Voice] new session discards pending preview")
            previewPresenter.close()
            previousApp = nil
        case .starting, .recording, .transcribing, .enhancing:
            DebugLog.log("[Voice] fnDown ignored: busy")
            return
        }

        generation &+= 1
        let gen = generation
        state = .starting(StartingContext(pressedAt: clock.now))
        activityModel.phase = .recording
        activityModel.level = 0
        activityModel.partialText = ""

        let hudEnabled = settings.voiceHUDEnabled
        let levelMeter: AudioLevelMeter? = hudEnabled
            ? AudioLevelMeter { [weak self] level in
                guard let self, gen == self.generation else { return }
                self.activityModel.level = level
            }
            : nil

        let transcriber = transcriberFactory(settings)
        let language = settings.voiceLanguage
        Task {
            var session: (any SpeechTranscriptionSession)?
            do {
                try await self.ensureMicrophonePermission()
                let newSession = try await transcriber.makeSession(language: language)
                session = newSession
                if hudEnabled {
                    newSession.setPartialHandler { text in
                        Task { @MainActor in
                            guard gen == self.generation else { return }
                            self.activityModel.partialText = text
                        }
                    }
                }
                try await self.recorder.start(
                    sink: { buffer in
                        newSession.append(buffer)
                        levelMeter?.ingest(buffer)
                    },
                    onConfigurationChange: {
                        Task { @MainActor in self.audioConfigurationChanged(gen: gen) }
                    }
                )
                self.engineDidStart(gen: gen, session: newSession, error: nil)
            } catch {
                session?.cancel()
                await self.recorder.stop()
                self.engineDidStart(gen: gen, session: nil, error: error)
            }
        }
    }

    func fnUp() {
        switch state {
        case .starting(var context):
            // Engine startup still in flight; record the intent and let
            // engineDidStart make the call once the session exists.
            context.stopRequested = true
            state = .starting(context)
        case .recording(let context):
            if heldLongEnough(since: context.pressedAt) {
                beginTranscribing(session: context.session)
            } else {
                DebugLog.log("[Voice] short press, cancelled")
                abandonSession(context.session)
            }
        case .idle, .transcribing, .enhancing, .previewing:
            break
        }
    }

    func fnInterrupted() {
        switch state {
        case .starting(var context):
            context.cancelled = true
            state = .starting(context)
        case .recording(let context):
            DebugLog.log("[Voice] Fn used as combo modifier, cancelled")
            abandonSession(context.session)
        case .idle, .transcribing, .enhancing, .previewing:
            break
        }
    }

    // MARK: - Async completions (gen-guarded)

    private func engineDidStart(gen: UInt64, session: (any SpeechTranscriptionSession)?, error: Error?) {
        guard gen == generation, case .starting(let context) = state else {
            // Stale: the session was superseded — clean up, don't touch state.
            session?.cancel()
            Task { await recorder.stop() }
            return
        }

        if let error {
            DebugLog.log("[Voice] failed to start recording: \(error)")
            toIdle()
            return
        }
        guard let session else {
            toIdle()
            return
        }

        if context.cancelled {
            abandonSession(session)
            return
        }
        if context.stopRequested {
            if heldLongEnough(since: context.pressedAt) {
                beginTranscribing(session: session)
            } else {
                DebugLog.log("[Voice] short press, cancelled")
                abandonSession(session)
            }
            return
        }

        state = .recording(RecordingContext(session: session, pressedAt: context.pressedAt))
        showHUDIfEnabled()
        scheduleMaxDuration(gen: gen)
    }

    private func transcriptionDidFinish(gen: UInt64, result: Result<String, Error>) {
        guard gen == generation, case .transcribing = state else { return }

        switch result {
        case .success(let text) where !text.isEmpty:
            DebugLog.log("[Voice] transcribed \(text.count) characters")
            if settings.voiceEnhanceEnabled {
                beginEnhancing(original: text)
            } else {
                deliver(text)
            }
        case .success:
            DebugLog.log("[Voice] empty transcription, nothing to paste")
            toIdle()
        case .failure(let error):
            DebugLog.log("[Voice] transcription failed: \(error)")
            toIdle()
        }
    }

    private func enhanceDidFinish(gen: UInt64, original: String, result: Result<String, Error>) {
        guard gen == generation, case .enhancing = state else { return }

        switch result {
        case .success(let text) where !text.isEmpty:
            DebugLog.log("[Voice] enhanced \(text.count) characters")
            deliver(text, original: original)
        case .success:
            DebugLog.log("[Voice] empty enhancement, falling back to transcription")
            deliver(original)
        case .failure(let error):
            DebugLog.log("[Voice] enhancement failed, falling back to transcription: \(error)")
            deliver(original)
        }
    }

    private func audioConfigurationChanged(gen: UInt64) {
        guard gen == generation, case .recording(let context) = state else { return }
        DebugLog.log("[Voice] audio configuration changed, cancelling session")
        abandonSession(context.session)
    }

    // MARK: - Transitions

    private func beginTranscribing(session: any SpeechTranscriptionSession) {
        let gen = generation
        state = .transcribing(session: session)
        activityModel.phase = .transcribing
        showHUDIfEnabled()
        maxDurationTask?.cancel()
        maxDurationTask = nil

        Task {
            await self.recorder.stop()
            do {
                let text = try await session.finish()
                self.transcriptionDidFinish(gen: gen, result: .success(text))
            } catch {
                self.transcriptionDidFinish(gen: gen, result: .failure(error))
            }
        }
        scheduleWatchdog(gen: gen, session: session)
    }

    private func beginEnhancing(original: String) {
        let gen = generation
        let enhancer = enhancerFactory(settings)
        let task = Task {
            do {
                let enhanced = try await enhancer.enhance(original)
                self.enhanceDidFinish(gen: gen, original: original, result: .success(enhanced))
            } catch {
                self.enhanceDidFinish(gen: gen, original: original, result: .failure(error))
            }
        }
        state = .enhancing(original: original, task: task)
        activityModel.phase = .enhancing
        watchdogTask?.cancel()
        scheduleEnhanceWatchdog(gen: gen, original: original)
    }

    /// Delivery of a finished session's text: preview if enabled, else paste
    /// directly and go idle. `original` is the raw transcription when `text`
    /// came from the enhancer, for the preview's read-only comparison.
    private func deliver(_ text: String, original: String? = nil) {
        if settings.voicePreviewEnabled {
            beginPreviewing(text: text, original: original)
        } else {
            pasteAction(text)
            toIdle()
        }
    }

    private func beginPreviewing(text: String, original: String?) {
        let gen = generation
        previousApp = frontmostAppProvider()
        state = .previewing
        activityModel.phase = .idle
        hideHUD()
        watchdogTask?.cancel()
        watchdogTask = nil
        previewPresenter.show(
            text: text,
            original: original,
            onConfirm: { [weak self] edited in self?.previewDidConfirm(gen: gen, text: edited) },
            onCancel: { [weak self] in self?.previewDidCancel(gen: gen) }
        )
    }

    private func previewDidConfirm(gen: UInt64, text: String) {
        guard gen == generation, case .previewing = state else { return }
        previewPresenter.close()
        let target = previousApp
        previousApp = nil
        toIdle()

        guard !text.isEmpty else { return }
        // Give the previous app time to become active again before ⌘V.
        Task {
            target?.activate()
            try? await Task.sleep(for: .milliseconds(150))
            self.pasteAction(text)
        }
    }

    private func previewDidCancel(gen: UInt64) {
        guard gen == generation, case .previewing = state else { return }
        DebugLog.log("[Voice] preview cancelled, text discarded")
        previewPresenter.close()
        previousApp = nil
        toIdle()
    }

    /// Cancels the given session, invalidates in-flight callbacks, returns to idle.
    private func abandonSession(_ session: any SpeechTranscriptionSession) {
        generation &+= 1
        session.cancel()
        Task { await recorder.stop() }
        toIdle()
    }

    private func abortActiveSession(reason: String) {
        switch state {
        case .idle:
            return
        case .starting(var context):
            context.cancelled = true
            state = .starting(context)
        case .recording(let context):
            DebugLog.log("[Voice] aborting session: \(reason)")
            abandonSession(context.session)
        case .transcribing(let session):
            DebugLog.log("[Voice] aborting transcription: \(reason)")
            abandonSession(session)
        case .enhancing(_, let task):
            DebugLog.log("[Voice] aborting enhancement: \(reason)")
            generation &+= 1
            task.cancel()
            toIdle()
        case .previewing:
            DebugLog.log("[Voice] discarding preview: \(reason)")
            generation &+= 1
            previewPresenter.close()
            previousApp = nil
            toIdle()
        }
    }

    private func toIdle() {
        state = .idle
        activityModel.phase = .idle
        activityModel.level = 0
        activityModel.partialText = ""
        hideHUD()
        maxDurationTask?.cancel()
        maxDurationTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func showHUDIfEnabled() {
        guard settings.voiceHUDEnabled else { return }
        hudPresenter.show()
        hudShown = true
    }

    private func hideHUD() {
        guard hudShown else { return }
        hudShown = false
        hudPresenter.hide()
    }

    private func heldLongEnough(since pressedAt: ContinuousClock.Instant) -> Bool {
        pressedAt.duration(to: clock.now) >= timing.minHold
    }

    // MARK: - Timers

    private func scheduleMaxDuration(gen: UInt64) {
        maxDurationTask?.cancel()
        maxDurationTask = Task { [maxRecording = timing.maxRecording] in
            try? await Task.sleep(for: maxRecording)
            guard !Task.isCancelled else { return }
            guard gen == self.generation, case .recording(let context) = self.state else { return }
            DebugLog.log("[Voice] max recording duration reached")
            self.beginTranscribing(session: context.session)
        }
    }

    private func scheduleWatchdog(gen: UInt64, session: any SpeechTranscriptionSession) {
        watchdogTask?.cancel()
        watchdogTask = Task { [timeout = timing.transcribeTimeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard gen == self.generation, case .transcribing = self.state else { return }
            DebugLog.log("[Voice] transcription watchdog fired, cancelling")
            self.abandonSession(session)
        }
    }

    private func scheduleEnhanceWatchdog(gen: UInt64, original: String) {
        watchdogTask?.cancel()
        watchdogTask = Task { [timeout = timing.enhanceTimeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard gen == self.generation, case .enhancing(_, let task) = self.state else { return }
            DebugLog.log("[Voice] enhancement watchdog fired, falling back to transcription")
            // Invalidate the in-flight enhance callback, then degrade.
            self.generation &+= 1
            task.cancel()
            self.deliver(original)
        }
    }

    // MARK: - Defaults

    private static let defaultTranscriberFactory: @MainActor (AppSettings) -> any SpeechTranscriber = { settings in
        switch settings.voiceBackend {
        case .apple:
            AppleSpeechTranscriber()
        case .whisperAPI:
            WhisperAPITranscriber(configuration: WhisperAPIConfiguration(
                baseURL: settings.voiceAPIBaseURL,
                apiKey: settings.voiceAPIKey,
                model: settings.voiceAPIModel
            ))
        }
    }

    private static let defaultEnhancerFactory: @MainActor (AppSettings) -> any TextEnhancer = { settings in
        LLMTextEnhancer(configuration: LLMEnhancerConfiguration(
            baseURL: settings.voiceEnhanceBaseURL,
            apiKey: settings.voiceEnhanceAPIKey,
            model: settings.voiceEnhanceModel,
            systemPrompt: settings.voiceEnhancePrompt
        ))
    }

    private static let defaultPasteAction: @MainActor (String) -> Void = { text in
        let pb = ClipboardStore.prepareTransientPasteboard(types: [.string])
        pb.setString(text, forType: .string)
        KeyboardUtils.simulatePaste()
    }

    private static let defaultMicrophonePermission: @Sendable () async throws -> Void = {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw TranscriptionError.notAuthorized }
        default:
            throw TranscriptionError.notAuthorized
        }
    }
}

// MARK: - VoiceKeyMonitorDelegate

extension VoiceInputController: VoiceKeyMonitorDelegate {
    func voiceKeyDidPress() { fnDown() }
    func voiceKeyDidRelease() { fnUp() }
    func voiceKeyWasInterrupted() { fnInterrupted() }
}
