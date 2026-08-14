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
/// Re-enhancements inside a preview session keep the same generation (the
/// panel's callbacks stay valid) and are invalidated via `enhanceGeneration`.
@MainActor
final class VoiceInputController {
    private let settings: AppSettings
    private let activityModel: VoiceActivityModel
    private let recorder: any AudioRecording
    private let transcriberFactory: (AppSettings) -> any SpeechTranscriber
    private let enhancerFactory: (AppSettings, String) -> any TextEnhancer
    /// Resolves a mode ID to its system prompt; nil disables enhancement.
    private let enhancePromptProvider: (String) -> String?
    /// Ordered mode list shown in the preview panel (⌘1-9 targets).
    private let enhanceModesProvider: () -> [EnhanceMode]
    /// Creates the per-recording audio retainer backing the preview panel's
    /// playback/save/re-transcribe features.
    private let audioRetainerFactory: () -> any AudioRetaining
    private let pasteAction: (String) -> Void
    /// Writes to the clipboard without pasting (⌘Return in the preview).
    private let copyAction: (String) -> Void
    private let ensureMicrophonePermission: @Sendable () async throws -> Void
    private let frontmostAppProvider: () -> NSRunningApplication?
    private let conversationHistory: ConversationHistory
    private let timing: VoiceInputTiming
    private let clock = ContinuousClock()

    private var monitor: VoiceKeyMonitor?
    private var generation: UInt64 = 0
    /// Bumped for every enhancement request; guards re-enhance callbacks
    /// whose session generation is still live.
    private var enhanceGeneration: UInt64 = 0
    private var state: State = .idle
    private var maxDurationTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// Last stream progress; the enhance watchdog fires on idle time, so a
    /// live stream keeps extending its deadline.
    private var enhanceProgressAt = ContinuousClock.now
    private var previousApp: NSRunningApplication?
    /// Length of the most recent recording, attached to history records.
    private var lastAudioDuration: Double = 0
    /// Audio of the in-flight recording, until a preview session takes it.
    private var currentAudio: (any AudioRetaining)?

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
        case transcribing(TranscribingContext)
        case enhancing(EnhancingContext)
        case previewing(PreviewSession)
        /// The panel's ASR model switch re-runs transcription on the
        /// session's retained audio.
        case reTranscribing(ReTranscribingContext)
    }

    private struct ReTranscribingContext {
        let session: PreviewSession
        let task: Task<Void, Never>
    }

    private struct TranscribingContext {
        let session: any SpeechTranscriptionSession
        /// The preview panel opened when transcription started; degrade
        /// paths keep it open instead of going idle.
        let panelOpen: Bool
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

    private struct EnhancingContext {
        let original: String
        let task: Task<Void, Never>
        /// Non-nil when this is a re-enhancement started from the preview
        /// panel; degrade paths return to the panel instead of going idle.
        let session: PreviewSession?
    }

    /// Per-recording preview context: the raw ASR text plus results for
    /// every (mode, LLM model) combination tried so far.
    final class PreviewSession {
        nonisolated struct CacheKey: Hashable, Sendable {
            var modeID: String
            var provider: String
            var model: String
        }

        let token: UUID
        /// Mutable: an in-panel ASR model switch re-transcribes and replaces it.
        var asrText: String
        var cache: [CacheKey: String] = [:]
        /// Last text displayed in the panel, for the user-corrected check.
        var lastShownText: String
        /// Length of the source recording in seconds; 0 for recalled entries.
        let audioDuration: Double
        /// Retained recording for playback/save/re-transcribe; nil for
        /// recalled history entries.
        let audio: (any AudioRetaining)?

        init(
            token: UUID = UUID(),
            asrText: String,
            lastShownText: String,
            audioDuration: Double,
            audio: (any AudioRetaining)? = nil
        ) {
            self.token = token
            self.asrText = asrText
            self.lastShownText = lastShownText
            self.audioDuration = audioDuration
            self.audio = audio
        }
    }

    // MARK: - Preview history (in-memory, newest first)

    private struct PreviewHistoryEntry {
        let token: UUID
        var asrText: String
        var results: [PreviewSession.CacheKey: String]
        var finalText: String?
        let date: Date
    }

    private static let previewHistoryLimit = 10
    private var previewHistory: [PreviewHistoryEntry] = []

    init(
        settings: AppSettings,
        activityModel: VoiceActivityModel,
        recorder: (any AudioRecording)? = nil,
        transcriberFactory: ((AppSettings) -> any SpeechTranscriber)? = nil,
        enhancerFactory: ((AppSettings, String) -> any TextEnhancer)? = nil,
        enhancePromptProvider: ((String) -> String?)? = nil,
        enhanceModesProvider: (() -> [EnhanceMode])? = nil,
        audioRetainerFactory: (() -> any AudioRetaining)? = nil,
        pasteAction: ((String) -> Void)? = nil,
        copyAction: ((String) -> Void)? = nil,
        ensureMicrophonePermission: (@Sendable () async throws -> Void)? = nil,
        previewPresenter: (any VoicePreviewPresenting)? = nil,
        hudPresenter: (any VoiceHUDPresenting)? = nil,
        frontmostAppProvider: (() -> NSRunningApplication?)? = nil,
        conversationHistory: ConversationHistory? = nil,
        timing: VoiceInputTiming = VoiceInputTiming()
    ) {
        self.settings = settings
        self.activityModel = activityModel
        self.recorder = recorder ?? VoiceAudioRecorder()
        self.transcriberFactory = transcriberFactory ?? Self.defaultTranscriberFactory
        self.enhancerFactory = enhancerFactory ?? Self.defaultEnhancerFactory
        self.enhancePromptProvider = enhancePromptProvider ?? { modeID in
            EnhanceModeStore().resolvePrompt(modeID: modeID)
        }
        self.enhanceModesProvider = enhanceModesProvider ?? { EnhanceModeStore().loadModes() }
        self.audioRetainerFactory = audioRetainerFactory ?? { RetainedAudio() }
        self.pasteAction = pasteAction ?? Self.defaultPasteAction
        self.copyAction = copyAction ?? Self.defaultCopyAction
        self.ensureMicrophonePermission = ensureMicrophonePermission ?? Self.defaultMicrophonePermission
        self.injectedPreviewPresenter = previewPresenter
        self.injectedHUDPresenter = hudPresenter
        self.frontmostAppProvider = frontmostAppProvider ?? { NSWorkspace.shared.frontmostApplication }
        self.conversationHistory = conversationHistory ?? ConversationHistory()
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

    /// Reopens the most recent preview from the in-memory history
    /// (menu bar entry). Only valid while idle.
    func showLastPreview() {
        guard case .idle = state, let entry = previewHistory.first else { return }
        generation &+= 1
        openHistoryEntry(entry)
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
        case .enhancing(let context) where context.session != nil:
            DebugLog.log("[Voice] new session discards re-enhancing preview")
            context.task.cancel()
            previewPresenter.close()
            previousApp = nil
        case .transcribing(let context) where context.panelOpen:
            // The recorder is already stopped; only the STT is in flight.
            DebugLog.log("[Voice] new session discards transcribing preview")
            context.session.cancel()
            previewPresenter.close()
            previousApp = nil
        case .reTranscribing(let context):
            DebugLog.log("[Voice] new session discards re-transcribing preview")
            context.task.cancel()
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

        // Retain the audio only when the preview panel will need it.
        let audio: (any AudioRetaining)? = settings.voicePreviewEnabled ? audioRetainerFactory() : nil
        currentAudio = audio

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
                        audio?.append(buffer)
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
                beginTranscribing(session: context.session, pressedAt: context.pressedAt)
            } else {
                DebugLog.log("[Voice] short press, cancelled")
                abandonSession(context.session)
            }
        case .idle, .transcribing, .enhancing, .previewing, .reTranscribing:
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
        case .idle, .transcribing, .enhancing, .previewing, .reTranscribing:
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
                beginTranscribing(session: session, pressedAt: context.pressedAt)
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

    /// Pushes the converted WAV to the open panel. Identity-checked against
    /// the owning session so a history recall (which keeps the generation)
    /// can't receive another recording's audio.
    private func audioDidBecomeAvailable(gen: UInt64, audio: any AudioRetaining, wavData: Data) {
        guard gen == generation else { return }
        switch state {
        case .transcribing(let context) where context.panelOpen:
            guard currentAudio === audio else { return }
        case .previewing(let session):
            guard session.audio === audio else { return }
        case .enhancing(let context):
            guard context.session?.audio === audio else { return }
        default:
            return
        }
        previewPresenter.setAudioAvailable(wavData: wavData)
    }

    private func transcriptionDidFinish(gen: UInt64, result: Result<String, Error>) {
        guard gen == generation, case .transcribing(let context) = state else { return }

        switch result {
        case .success(let text) where !text.isEmpty:
            DebugLog.log("[Voice] transcribed \(text.count) characters")
            if context.panelOpen {
                let session = PreviewSession(
                    asrText: text, lastShownText: text, audioDuration: lastAudioDuration,
                    audio: takeCurrentAudio()
                )
                insertHistoryEntry(for: session)
                previewPresenter.setASRResult(text: text, asrInfo: asrInfoText(for: session))
                if let prompt = enhancePromptProvider(settings.voiceEnhanceMode) {
                    beginEnhancing(original: text, prompt: prompt, session: session)
                } else {
                    becomePreviewing(session)
                }
            } else if let prompt = enhancePromptProvider(settings.voiceEnhanceMode) {
                beginEnhancing(original: text, prompt: prompt, session: nil)
            } else {
                deliver(text)
            }
        case .success:
            DebugLog.log("[Voice] empty transcription, nothing to paste")
            if context.panelOpen {
                presentTranscriptionFailure("Empty transcription")
            } else {
                toIdle()
            }
        case .failure(let error):
            DebugLog.log("[Voice] transcription failed: \(error)")
            if context.panelOpen {
                presentTranscriptionFailure("Transcription failed")
            } else {
                toIdle()
            }
        }
    }

    /// The open panel stays up showing the failure; the user can dismiss it
    /// or type a final text manually. The session carries no ASR text, so
    /// mode switches and history recording are skipped for it.
    private func presentTranscriptionFailure(_ message: String) {
        // The session keeps the audio: switching the ASR model in the panel
        // can re-transcribe and recover a failed transcription.
        let session = PreviewSession(
            asrText: "", lastShownText: "", audioDuration: lastAudioDuration,
            audio: takeCurrentAudio()
        )
        becomePreviewing(session)
        previewPresenter.setASRFailed(message: message)
    }

    /// Transfers ownership of the retained audio to a new preview session.
    private func takeCurrentAudio() -> (any AudioRetaining)? {
        let audio = currentAudio
        currentAudio = nil
        return audio
    }

    /// Transition to previewing without touching the panel content.
    private func becomePreviewing(_ session: PreviewSession) {
        state = .previewing(session)
        activityModel.phase = .idle
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func enhanceDeltaArrived(gen: UInt64, eGen: UInt64, delta: String) {
        guard gen == generation, eGen == enhanceGeneration,
              case .enhancing = state else { return }
        enhanceProgressAt = clock.now
        previewPresenter.appendEnhanceDelta(delta)
    }

    private func enhanceDidFinish(gen: UInt64, eGen: UInt64, original: String, result: Result<String, Error>) {
        guard gen == generation, eGen == enhanceGeneration,
              case .enhancing(let context) = state else { return }

        switch result {
        case .success(let text) where !text.isEmpty:
            DebugLog.log("[Voice] enhanced \(text.count) characters")
            if let session = context.session {
                session.cache[currentCacheKey()] = text
                returnToPreview(session, text: text, original: session.asrText, isCached: false)
            } else {
                deliver(text, original: original)
            }
        case .success:
            DebugLog.log("[Voice] empty enhancement, falling back to transcription")
            degradeEnhancement(context, original: original)
        case .failure(let error):
            DebugLog.log("[Voice] enhancement failed, falling back to transcription: \(error)")
            degradeEnhancement(context, original: original)
        }
    }

    /// Failed/empty enhancement: initial runs deliver the raw transcription;
    /// panel re-enhancements return to the panel showing the ASR text.
    private func degradeEnhancement(_ context: EnhancingContext, original: String) {
        if let session = context.session {
            returnToPreview(session, text: session.asrText, original: nil, isCached: false)
        } else {
            deliver(original)
        }
    }

    private func audioConfigurationChanged(gen: UInt64) {
        guard gen == generation, case .recording(let context) = state else { return }
        DebugLog.log("[Voice] audio configuration changed, cancelling session")
        abandonSession(context.session)
    }

    // MARK: - Transitions

    private func beginTranscribing(session: any SpeechTranscriptionSession, pressedAt: ContinuousClock.Instant) {
        let gen = generation
        let held = pressedAt.duration(to: clock.now)
        lastAudioDuration = Double(held.components.seconds)
            + Double(held.components.attoseconds) / 1e18
        let panelOpen = settings.voicePreviewEnabled
        state = .transcribing(TranscribingContext(session: session, panelOpen: panelOpen))
        activityModel.phase = .transcribing
        currentAudio?.stopAccepting()
        if panelOpen, let audio = currentAudio {
            // Convert eagerly: releases the raw buffers early and enables the
            // panel's playback/save buttons as soon as the WAV is ready.
            Task {
                guard let wavData = try? await audio.wavData() else { return }
                self.audioDidBecomeAvailable(gen: gen, audio: audio, wavData: wavData)
            }
        }
        if panelOpen {
            // WenZi-style: the preview opens right away with the ASR area
            // in a loading state; it replaces the HUD from here on.
            presentTranscribingPanel()
        } else {
            showHUDIfEnabled()
        }
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

    private func beginEnhancing(original: String, prompt: String, session: PreviewSession?) {
        let gen = generation
        enhanceGeneration &+= 1
        let eGen = enhanceGeneration
        let task = Task {
            // Confirmed corrections from previous sessions are appended to
            // the prompt; failures degrade to the bare mode prompt.
            var fullPrompt = prompt
            if self.settings.voiceHistoryEnabled,
               let block = await self.conversationHistory.injectionBlock(mode: self.settings.voiceEnhanceMode) {
                fullPrompt += "\n\n" + block
            }
            let enhancer = self.enhancerFactory(self.settings, fullPrompt)
            do {
                let enhanced: String
                if session != nil {
                    // Panel path: stream chunks into the enhance area.
                    enhanced = try await enhancer.enhanceStream(original) { delta in
                        Task { @MainActor in
                            self.enhanceDeltaArrived(gen: gen, eGen: eGen, delta: delta)
                        }
                    }
                } else {
                    // Direct-paste path: nowhere to show deltas.
                    enhanced = try await enhancer.enhance(original)
                }
                self.enhanceDidFinish(gen: gen, eGen: eGen, original: original, result: .success(enhanced))
            } catch {
                self.enhanceDidFinish(gen: gen, eGen: eGen, original: original, result: .failure(error))
            }
        }
        state = .enhancing(EnhancingContext(original: original, task: task, session: session))
        activityModel.phase = .enhancing
        if session != nil {
            previewPresenter.setEnhancing(true)
        }
        watchdogTask?.cancel()
        scheduleEnhanceWatchdog(gen: gen, eGen: eGen, original: original)
    }

    /// Delivery of a finished session's text: preview if enabled, else paste
    /// directly and go idle. `original` is the raw transcription when `text`
    /// came from the enhancer, for the preview's read-only comparison.
    private func deliver(_ text: String, original: String? = nil) {
        if settings.voicePreviewEnabled {
            beginPreviewing(text: text, original: original)
        } else {
            pasteAction(text)
            recordHistory(
                asrText: original ?? text,
                enhancedText: original != nil ? text : nil,
                finalText: text,
                previewEnabled: false,
                userCorrected: false,
                audioDuration: lastAudioDuration
            )
            toIdle()
        }
    }

    private func beginPreviewing(text: String, original: String?) {
        let session = PreviewSession(
            asrText: original ?? text,
            lastShownText: text,
            audioDuration: lastAudioDuration,
            audio: takeCurrentAudio()
        )
        if original != nil {
            // Seed the cache with the initial enhancement result.
            session.cache[currentCacheKey()] = text
        }
        insertHistoryEntry(for: session)
        presentPreview(session: session, text: text, original: original, isCached: false)
    }

    private func insertHistoryEntry(for session: PreviewSession) {
        previewHistory.insert(PreviewHistoryEntry(
            token: session.token,
            asrText: session.asrText,
            results: session.cache,
            finalText: nil,
            date: Date()
        ), at: 0)
        if previewHistory.count > Self.previewHistoryLimit {
            previewHistory.removeLast(previewHistory.count - Self.previewHistoryLimit)
        }
    }

    /// Opens the panel while transcription is still running; the ASR result
    /// arrives later via `setASRResult`/`setASRFailed`.
    private func presentTranscribingPanel() {
        previousApp = frontmostAppProvider()
        hideHUD()
        let setup = VoicePreviewSetup(
            text: "",
            original: nil,
            asrInfo: asrInfoText(duration: lastAudioDuration),
            isTranscribing: true,
            asrOptions: asrOptions(),
            currentASR: currentResolvedASR(),
            modes: enhanceModesProvider(),
            currentModeID: settings.voiceEnhanceMode,
            llmOptions: llmOptions(),
            currentLLM: currentResolvedLLM(),
            isCached: false,
            history: historyMenuItems()
        )
        previewPresenter.show(setup: setup, callbacks: makePreviewCallbacks(gen: generation))
    }

    private func presentPreview(session: PreviewSession, text: String, original: String?, isCached: Bool) {
        previousApp = frontmostAppProvider()
        state = .previewing(session)
        activityModel.phase = .idle
        hideHUD()
        watchdogTask?.cancel()
        watchdogTask = nil

        let setup = VoicePreviewSetup(
            text: text,
            original: original,
            asrInfo: asrInfoText(for: session),
            asrOptions: asrOptions(),
            currentASR: currentResolvedASR(),
            modes: enhanceModesProvider(),
            currentModeID: settings.voiceEnhanceMode,
            llmOptions: llmOptions(),
            currentLLM: currentResolvedLLM(),
            isCached: isCached,
            history: historyMenuItems()
        )
        previewPresenter.show(setup: setup, callbacks: makePreviewCallbacks(gen: generation))
    }

    private func makePreviewCallbacks(gen: UInt64) -> VoicePreviewCallbacks {
        VoicePreviewCallbacks(
            onConfirm: { [weak self] text in self?.previewDidConfirm(gen: gen, text: text) },
            onCopy: { [weak self] text in self?.previewDidCopy(gen: gen, text: text) },
            onCancel: { [weak self] in self?.previewDidCancel(gen: gen) },
            onModeSwitch: { [weak self] modeID in self?.previewDidSwitchMode(gen: gen, modeID: modeID) },
            onModelSwitch: { [weak self] selection in self?.previewDidSwitchModel(gen: gen, selection: selection) },
            onASRSwitch: { [weak self] selection in self?.previewDidSwitchASR(gen: gen, selection: selection) },
            onHistorySelect: { [weak self] token in self?.previewDidSelectHistory(gen: gen, token: token) }
        )
    }

    private func llmOptions() -> [LLMSelection] {
        settings.voiceLLMProviders.flatMap { provider in
            provider.models.map { LLMSelection(provider: provider.name, model: $0) }
        }
    }

    private func asrOptions() -> [ASRSelection] {
        [.apple] + settings.voiceASRProviders.flatMap { provider in
            provider.models.map { ASRSelection.remote(provider: provider.name, model: $0) }
        }
    }

    private func currentResolvedASR() -> ASRSelection {
        switch VoiceProviderResolver.resolveASR(
            selection: settings.voiceASRSelection, providers: settings.voiceASRProviders
        ) {
        case .apple: .apple
        case .remote(let provider, let model): .remote(provider: provider.name, model: model)
        }
    }

    private func historyMenuItems() -> [VoicePreviewHistoryMenuItem] {
        previewHistory.map { entry in
            VoicePreviewHistoryMenuItem(id: entry.token, title: Self.historyTitle(entry))
        }
    }

    /// Back from a re-enhancement (result, cache hit or degrade) to the
    /// open panel.
    private func returnToPreview(_ session: PreviewSession, text: String, original: String?, isCached: Bool) {
        state = .previewing(session)
        activityModel.phase = .idle
        session.lastShownText = text
        watchdogTask?.cancel()
        watchdogTask = nil
        previewPresenter.update(
            text: text,
            original: original,
            currentModeID: settings.voiceEnhanceMode,
            currentLLM: currentResolvedLLM(),
            isCached: isCached
        )
        syncHistoryResults(session)
    }

    private func previewDidConfirm(gen: UInt64, text: String) {
        guard gen == generation else { return }
        switch state {
        case .previewing(let session):
            previewPresenter.close()
            recordFinalText(text, for: session)
            let target = previousApp
            previousApp = nil
            toIdle()

            guard !text.isEmpty else { return }
            if !session.asrText.isEmpty {
                recordSessionHistory(session, finalText: text)
            }
            // Give the previous app time to become active again before ⌘V.
            Task {
                target?.activate()
                try? await Task.sleep(for: .milliseconds(150))
                self.pasteAction(text)
            }
        case .transcribing(let context) where context.panelOpen:
            // Confirm while STT is still running: abort it and paste
            // whatever the user typed (usually nothing).
            DebugLog.log("[Voice] preview confirmed during transcription, aborting STT")
            previewPresenter.close()
            generation &+= 1
            context.session.cancel()
            let target = previousApp
            previousApp = nil
            toIdle()

            guard !text.isEmpty else { return }
            Task {
                target?.activate()
                try? await Task.sleep(for: .milliseconds(150))
                self.pasteAction(text)
            }
        case .reTranscribing(let context):
            // Confirm while re-transcribing: abort it and paste the panel's
            // current final text (based on the previous ASR result).
            DebugLog.log("[Voice] preview confirmed during re-transcription")
            previewPresenter.close()
            context.task.cancel()
            recordFinalText(text, for: context.session)
            let target = previousApp
            previousApp = nil
            toIdle()

            guard !text.isEmpty else { return }
            if !context.session.asrText.isEmpty {
                recordSessionHistory(context.session, finalText: text)
            }
            Task {
                target?.activate()
                try? await Task.sleep(for: .milliseconds(150))
                self.pasteAction(text)
            }
        default:
            return
        }
    }

    private func previewDidCopy(gen: UInt64, text: String) {
        guard gen == generation else { return }
        switch state {
        case .previewing(let session):
            DebugLog.log("[Voice] preview copied to clipboard without pasting")
            previewPresenter.close()
            recordFinalText(text, for: session)
            previousApp = nil
            toIdle()

            guard !text.isEmpty else { return }
            if !session.asrText.isEmpty {
                recordSessionHistory(session, finalText: text)
            }
            copyAction(text)
        case .transcribing(let context) where context.panelOpen:
            DebugLog.log("[Voice] preview copied during transcription, aborting STT")
            previewPresenter.close()
            generation &+= 1
            context.session.cancel()
            previousApp = nil
            toIdle()

            guard !text.isEmpty else { return }
            copyAction(text)
        case .reTranscribing(let context):
            DebugLog.log("[Voice] preview copied during re-transcription")
            previewPresenter.close()
            context.task.cancel()
            recordFinalText(text, for: context.session)
            previousApp = nil
            toIdle()

            guard !text.isEmpty else { return }
            if !context.session.asrText.isEmpty {
                recordSessionHistory(context.session, finalText: text)
            }
            copyAction(text)
        default:
            return
        }
    }

    private func previewDidCancel(gen: UInt64) {
        guard gen == generation else { return }
        switch state {
        case .previewing:
            DebugLog.log("[Voice] preview cancelled, text discarded")
        case .enhancing(let context) where context.session != nil:
            DebugLog.log("[Voice] preview cancelled during re-enhancement")
            enhanceGeneration &+= 1
            context.task.cancel()
        case .reTranscribing(let context):
            DebugLog.log("[Voice] preview cancelled during re-transcription")
            context.task.cancel()
        case .transcribing(let context) where context.panelOpen:
            DebugLog.log("[Voice] preview cancelled during transcription")
            previewPresenter.close()
            previousApp = nil
            abandonSession(context.session)
            return
        default:
            return
        }
        previewPresenter.close()
        previousApp = nil
        toIdle()
    }

    private func previewDidSwitchMode(gen: UInt64, modeID: String) {
        guard gen == generation else { return }
        if case .transcribing(let context) = state, context.panelOpen {
            // ASR not ready yet: just remember the mode for the upcoming
            // enhancement (and future sessions).
            DebugLog.log("[Voice] preview mode preselected: \(modeID)")
            settings.voiceEnhanceMode = modeID
            return
        }
        guard let session = interruptPreviewSession() else { return }
        if case .previewing = state, settings.voiceEnhanceMode == modeID { return }
        DebugLog.log("[Voice] preview mode switched to \(modeID)")
        settings.voiceEnhanceMode = modeID
        refreshPreview(session)
    }

    private func previewDidSwitchModel(gen: UInt64, selection: LLMSelection) {
        guard gen == generation else { return }
        if case .transcribing(let context) = state, context.panelOpen {
            DebugLog.log("[Voice] preview LLM preselected: \(selection.provider)/\(selection.model)")
            settings.voiceLLMSelection = selection
            return
        }
        guard let session = interruptPreviewSession() else { return }
        if case .previewing = state, settings.voiceLLMSelection == selection { return }
        DebugLog.log("[Voice] preview LLM switched to \(selection.provider)/\(selection.model)")
        settings.voiceLLMSelection = selection
        refreshPreview(session)
    }

    private func previewDidSwitchASR(gen: UInt64, selection: ASRSelection) {
        guard gen == generation else { return }
        if case .transcribing(let context) = state, context.panelOpen {
            // ASR still running: just remember the model for future sessions.
            DebugLog.log("[Voice] preview ASR preselected: \(Self.describeASR(selection))")
            settings.voiceASRSelection = selection
            return
        }
        guard let session = interruptPreviewSession() else { return }
        if settings.voiceASRSelection == selection { return }
        settings.voiceASRSelection = selection
        guard session.audio != nil else {
            // Recalled history entries carry no audio; only persist the choice.
            DebugLog.log("[Voice] ASR switch persisted, no retained audio to re-transcribe")
            return
        }
        DebugLog.log("[Voice] preview ASR switched to \(Self.describeASR(selection))")
        beginReTranscribing(session)
    }

    private func beginReTranscribing(_ session: PreviewSession) {
        guard let audio = session.audio else { return }
        let gen = generation
        // The result of any in-flight enhancement would apply to the old
        // ASR text; invalidate it.
        enhanceGeneration &+= 1
        let transcriber = transcriberFactory(settings)
        let language = settings.voiceLanguage
        let task = Task {
            do {
                let wavData = try await audio.wavData()
                let text = try await transcriber.transcribe(wavData: wavData, language: language)
                self.reTranscribeDidFinish(gen: gen, result: .success(text))
            } catch {
                self.reTranscribeDidFinish(gen: gen, result: .failure(error))
            }
        }
        state = .reTranscribing(ReTranscribingContext(session: session, task: task))
        activityModel.phase = .transcribing
        previewPresenter.setEnhancing(false)
        previewPresenter.setASRTranscribing(info: asrInfoText(for: session))
        scheduleReTranscribeWatchdog(gen: gen)
    }

    private func reTranscribeDidFinish(gen: UInt64, result: Result<String, Error>) {
        guard gen == generation, case .reTranscribing(let context) = state else { return }
        let session = context.session

        switch result {
        case .success(let text) where !text.isEmpty:
            DebugLog.log("[Voice] re-transcribed \(text.count) characters")
            session.asrText = text
            // The source text changed: every cached enhancement is stale.
            session.cache.removeAll()
            session.lastShownText = text
            if previewHistory.contains(where: { $0.token == session.token }) {
                syncHistoryASRText(session)
            } else {
                // Failed-transcription sessions weren't listed; a successful
                // re-transcription makes them a real history entry.
                insertHistoryEntry(for: session)
            }
            previewPresenter.setASRResult(text: text, asrInfo: asrInfoText(for: session))
            becomePreviewing(session)
            refreshPreview(session)
        case .success:
            DebugLog.log("[Voice] empty re-transcription, keeping previous text")
            showReTranscribeFailure(session, message: "Empty re-transcription")
        case .failure(let error):
            DebugLog.log("[Voice] re-transcription failed: \(error)")
            showReTranscribeFailure(session, message: "Re-transcription failed")
        }
    }

    /// Failed re-transcription keeps the previous ASR text usable; sessions
    /// that never had a transcription show the failure message instead.
    private func showReTranscribeFailure(_ session: PreviewSession, message: String) {
        becomePreviewing(session)
        if session.asrText.isEmpty {
            previewPresenter.setASRFailed(message: message)
        } else {
            previewPresenter.setASRResult(
                text: session.asrText,
                asrInfo: asrInfoText(for: session) + " · switch failed"
            )
        }
    }

    private static func describeASR(_ selection: ASRSelection) -> String {
        switch selection {
        case .apple: "apple"
        case .remote(let provider, let model): "\(provider)/\(model)"
        }
    }

    private func previewDidSelectHistory(gen: UInt64, token: UUID) {
        guard gen == generation else { return }
        if case .transcribing(let context) = state, context.panelOpen {
            guard let index = previewHistory.firstIndex(where: { $0.token == token }) else { return }
            DebugLog.log("[Voice] recalling history during transcription, aborting STT")
            context.session.cancel()
            let entry = previewHistory.remove(at: index)
            previewHistory.insert(entry, at: 0)
            openHistoryEntry(entry)
            return
        }
        guard let session = interruptPreviewSession() else { return }
        guard token != session.token,
              let index = previewHistory.firstIndex(where: { $0.token == token }) else {
            // Re-selecting the current entry: just make sure we're previewing.
            if case .enhancing = state { returnToPreview(session, text: session.asrText, original: nil, isCached: false) }
            return
        }
        DebugLog.log("[Voice] recalling preview from history")
        let entry = previewHistory.remove(at: index)
        previewHistory.insert(entry, at: 0)
        openHistoryEntry(entry)
    }

    private func openHistoryEntry(_ entry: PreviewHistoryEntry) {
        let text = entry.finalText ?? entry.results[currentCacheKey()] ?? entry.asrText
        let session = PreviewSession(
            token: entry.token,
            asrText: entry.asrText,
            lastShownText: text,
            audioDuration: 0
        )
        session.cache = entry.results
        presentPreview(
            session: session,
            text: text,
            original: text == entry.asrText ? nil : entry.asrText,
            isCached: false
        )
    }

    /// The active preview session, cancelling an in-flight re-enhancement or
    /// re-transcription if there is one (the caller is about to start a new
    /// operation or take over).
    private func interruptPreviewSession() -> PreviewSession? {
        switch state {
        case .previewing(let session):
            return session
        case .enhancing(let context):
            guard let session = context.session else { return nil }
            enhanceGeneration &+= 1
            context.task.cancel()
            return session
        case .reTranscribing(let context):
            context.task.cancel()
            // Restore the ASR area and drop back to previewing so the
            // caller takes over from a stable state.
            let session = context.session
            if session.asrText.isEmpty {
                previewPresenter.setASRFailed(message: "Re-transcription cancelled")
            } else {
                previewPresenter.setASRResult(text: session.asrText, asrInfo: asrInfoText(for: session))
            }
            becomePreviewing(session)
            return session
        default:
            return nil
        }
    }

    /// Re-runs enhancement for the current (mode, model) combination, using
    /// the cache when this combination was already tried in this session.
    private func refreshPreview(_ session: PreviewSession) {
        // Failed-transcription sessions carry no ASR text to enhance.
        guard !session.asrText.isEmpty else { return }
        let modeID = settings.voiceEnhanceMode
        if let cached = session.cache[currentCacheKey()] {
            DebugLog.log("[Voice] preview cache hit")
            returnToPreview(session, text: cached, original: session.asrText, isCached: true)
            return
        }
        guard let prompt = enhancePromptProvider(modeID) else {
            returnToPreview(session, text: session.asrText, original: nil, isCached: false)
            return
        }
        beginEnhancing(original: session.asrText, prompt: prompt, session: session)
    }

    // MARK: - Conversation history (JSONL)

    private func recordSessionHistory(_ session: PreviewSession, finalText: String) {
        recordHistory(
            asrText: session.asrText,
            enhancedText: session.lastShownText != session.asrText ? session.lastShownText : nil,
            finalText: finalText,
            previewEnabled: true,
            userCorrected: finalText != session.lastShownText,
            audioDuration: session.audioDuration
        )
    }

    private func recordHistory(
        asrText: String,
        enhancedText: String?,
        finalText: String,
        previewEnabled: Bool,
        userCorrected: Bool,
        audioDuration: Double
    ) {
        guard settings.voiceHistoryEnabled else { return }
        let record = ConversationRecord(
            timestamp: ConversationRecord.makeTimestamp(),
            asrText: asrText,
            enhancedText: enhancedText,
            finalText: finalText,
            enhanceMode: settings.voiceEnhanceMode,
            previewEnabled: previewEnabled,
            asrModel: currentASRModelDescription(),
            llmModel: currentLLMModelDescription(),
            userCorrected: userCorrected,
            audioDuration: audioDuration
        )
        let history = conversationHistory
        Task { await history.record(record) }
    }

    /// ASR section info line, e.g. "apple · 3.2s". Recalled history entries
    /// have no duration.
    private func asrInfoText(for session: PreviewSession) -> String {
        asrInfoText(duration: session.audioDuration)
    }

    private func asrInfoText(duration: Double) -> String {
        let model = currentASRModelDescription()
        guard duration > 0 else { return model }
        return String(format: "%@ · %.1fs", model, duration)
    }

    private func currentASRModelDescription() -> String {
        switch settings.voiceASRSelection {
        case .apple:
            return "apple"
        case .remote(let provider, let model):
            return "\(provider)/\(model)"
        }
    }

    private func currentLLMModelDescription() -> String {
        guard let llm = currentResolvedLLM() else { return "" }
        return "\(llm.provider)/\(llm.model)"
    }

    // MARK: - History bookkeeping

    private func syncHistoryResults(_ session: PreviewSession) {
        guard let index = previewHistory.firstIndex(where: { $0.token == session.token }) else { return }
        previewHistory[index].results = session.cache
    }

    private func syncHistoryASRText(_ session: PreviewSession) {
        guard let index = previewHistory.firstIndex(where: { $0.token == session.token }) else { return }
        previewHistory[index].asrText = session.asrText
        previewHistory[index].results = session.cache
    }

    private func recordFinalText(_ text: String, for session: PreviewSession) {
        guard let index = previewHistory.firstIndex(where: { $0.token == session.token }) else { return }
        previewHistory[index].finalText = text
        previewHistory[index].results = session.cache
    }

    private static let historyTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func historyTitle(_ entry: PreviewHistoryEntry) -> String {
        let text = entry.finalText ?? entry.asrText
        let snippet = text.count > 30 ? String(text.prefix(30)) + "…" : text
        return "\(historyTimeFormatter.string(from: entry.date))  \(snippet)"
    }

    // MARK: - Cache key helpers

    private func currentResolvedLLM() -> LLMSelection? {
        guard let resolved = VoiceProviderResolver.resolveLLM(
            selection: settings.voiceLLMSelection, providers: settings.voiceLLMProviders
        ) else { return nil }
        return LLMSelection(provider: resolved.provider.name, model: resolved.model)
    }

    private func currentCacheKey() -> PreviewSession.CacheKey {
        let llm = currentResolvedLLM()
        return PreviewSession.CacheKey(
            modeID: settings.voiceEnhanceMode,
            provider: llm?.provider ?? "",
            model: llm?.model ?? ""
        )
    }

    // MARK: - Cleanup

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
        case .transcribing(let context):
            DebugLog.log("[Voice] aborting transcription: \(reason)")
            if context.panelOpen {
                previewPresenter.close()
                previousApp = nil
            }
            abandonSession(context.session)
        case .enhancing(let context):
            DebugLog.log("[Voice] aborting enhancement: \(reason)")
            generation &+= 1
            context.task.cancel()
            if context.session != nil {
                previewPresenter.close()
                previousApp = nil
            }
            toIdle()
        case .reTranscribing(let context):
            DebugLog.log("[Voice] aborting re-transcription: \(reason)")
            generation &+= 1
            context.task.cancel()
            previewPresenter.close()
            previousApp = nil
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
        currentAudio = nil
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
            self.beginTranscribing(session: context.session, pressedAt: context.pressedAt)
        }
    }

    private func scheduleWatchdog(gen: UInt64, session: any SpeechTranscriptionSession) {
        watchdogTask?.cancel()
        watchdogTask = Task { [timeout = timing.transcribeTimeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard gen == self.generation, case .transcribing(let context) = self.state else { return }
            if context.panelOpen {
                // Keep the panel (and its gen-bound callbacks) alive; the
                // late finish is discarded by the state check.
                DebugLog.log("[Voice] transcription watchdog fired, showing failure in preview")
                session.cancel()
                self.presentTranscriptionFailure("Transcription timed out")
            } else {
                DebugLog.log("[Voice] transcription watchdog fired, cancelling")
                self.abandonSession(session)
            }
        }
    }

    private func scheduleReTranscribeWatchdog(gen: UInt64) {
        watchdogTask?.cancel()
        watchdogTask = Task { [timeout = timing.transcribeTimeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard gen == self.generation, case .reTranscribing(let context) = self.state else { return }
            DebugLog.log("[Voice] re-transcription watchdog fired, keeping previous text")
            context.task.cancel()
            self.showReTranscribeFailure(context.session, message: "Re-transcription timed out")
        }
    }

    /// Idle-based: a streaming enhancement extends its deadline with every
    /// delta; the watchdog fires only after `enhanceTimeout` without progress.
    private func scheduleEnhanceWatchdog(gen: UInt64, eGen: UInt64, original: String) {
        watchdogTask?.cancel()
        enhanceProgressAt = clock.now
        watchdogTask = Task { [timeout = timing.enhanceTimeout] in
            while true {
                let deadline = self.enhanceProgressAt.advanced(by: timeout)
                let now = self.clock.now
                guard deadline > now else { break }
                try? await Task.sleep(for: now.duration(to: deadline))
                guard !Task.isCancelled else { return }
            }
            guard gen == self.generation, eGen == self.enhanceGeneration,
                  case .enhancing(let context) = self.state else { return }
            // Invalidate the in-flight enhance callback, then degrade.
            if let session = context.session {
                DebugLog.log("[Voice] re-enhancement watchdog fired, back to preview")
                self.enhanceGeneration &+= 1
                context.task.cancel()
                self.returnToPreview(session, text: session.asrText, original: nil, isCached: false)
            } else {
                DebugLog.log("[Voice] enhancement watchdog fired, falling back to transcription")
                self.generation &+= 1
                context.task.cancel()
                self.deliver(original)
            }
        }
    }

    // MARK: - Defaults

    private static let defaultTranscriberFactory: @MainActor (AppSettings) -> any SpeechTranscriber = { settings in
        let selection = settings.voiceASRSelection
        switch VoiceProviderResolver.resolveASR(selection: selection, providers: settings.voiceASRProviders) {
        case .apple:
            if selection != .apple {
                DebugLog.log("[Voice] ASR selection unresolved, falling back to Apple Speech")
            }
            return AppleSpeechTranscriber()
        case .remote(let provider, let model):
            if selection != .remote(provider: provider.name, model: model) {
                DebugLog.log("[Voice] ASR model unresolved, using \(provider.name)/\(model)")
            }
            return WhisperAPITranscriber(configuration: WhisperAPIConfiguration(
                baseURL: provider.baseURL,
                apiKey: provider.apiKey,
                model: model
            ))
        }
    }

    private static let defaultEnhancerFactory: @MainActor (AppSettings, String) -> any TextEnhancer = { settings, prompt in
        let selection = settings.voiceLLMSelection
        guard let resolved = VoiceProviderResolver.resolveLLM(
            selection: selection, providers: settings.voiceLLMProviders
        ) else {
            // No provider configured: the enhancer will fail and the
            // controller degrades to the raw transcription.
            DebugLog.log("[Voice] no LLM provider configured for enhancement")
            return LLMTextEnhancer(configuration: LLMEnhancerConfiguration(
                baseURL: "", apiKey: "", model: "",
                systemPrompt: prompt
            ))
        }
        if resolved.provider.name != selection.provider || resolved.model != selection.model {
            DebugLog.log("[Voice] LLM selection unresolved, using \(resolved.provider.name)/\(resolved.model)")
        }
        return LLMTextEnhancer(configuration: LLMEnhancerConfiguration(
            baseURL: resolved.provider.baseURL,
            apiKey: resolved.provider.apiKey,
            model: resolved.model,
            systemPrompt: prompt
        ))
    }

    private static let defaultPasteAction: @MainActor (String) -> Void = { text in
        let pb = ClipboardStore.prepareTransientPasteboard(types: [.string])
        pb.setString(text, forType: .string)
        KeyboardUtils.simulatePaste()
    }

    private static let defaultCopyAction: @MainActor (String) -> Void = { text in
        let pb = ClipboardStore.prepareTransientPasteboard(types: [.string])
        pb.setString(text, forType: .string)
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
