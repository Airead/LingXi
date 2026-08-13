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
    private let pasteAction: (String) -> Void
    private let ensureMicrophonePermission: @Sendable () async throws -> Void
    private let timing: VoiceInputTiming
    private let clock = ContinuousClock()

    private var monitor: VoiceKeyMonitor?
    private var generation: UInt64 = 0
    private var state: State = .idle
    private var maxDurationTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    private enum State {
        case idle
        case starting(StartingContext)
        case recording(RecordingContext)
        case transcribing(session: any SpeechTranscriptionSession)
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
        pasteAction: ((String) -> Void)? = nil,
        ensureMicrophonePermission: (@Sendable () async throws -> Void)? = nil,
        timing: VoiceInputTiming = VoiceInputTiming()
    ) {
        self.settings = settings
        self.activityModel = activityModel
        self.recorder = recorder ?? VoiceAudioRecorder()
        self.transcriberFactory = transcriberFactory ?? Self.defaultTranscriberFactory
        self.pasteAction = pasteAction ?? Self.defaultPasteAction
        self.ensureMicrophonePermission = ensureMicrophonePermission ?? Self.defaultMicrophonePermission
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
        guard case .idle = state else {
            DebugLog.log("[Voice] fnDown ignored: busy")
            return
        }

        generation &+= 1
        let gen = generation
        state = .starting(StartingContext(pressedAt: clock.now))
        activityModel.phase = .recording

        let transcriber = transcriberFactory(settings)
        let language = settings.voiceLanguage
        Task {
            var session: (any SpeechTranscriptionSession)?
            do {
                try await self.ensureMicrophonePermission()
                let newSession = try await transcriber.makeSession(language: language)
                session = newSession
                try await self.recorder.start(
                    sink: { buffer in newSession.append(buffer) },
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
        case .idle, .transcribing:
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
        case .idle, .transcribing:
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
        scheduleMaxDuration(gen: gen)
    }

    private func transcriptionDidFinish(gen: UInt64, result: Result<String, Error>) {
        guard gen == generation, case .transcribing = state else { return }

        switch result {
        case .success(let text) where !text.isEmpty:
            DebugLog.log("[Voice] transcribed \(text.count) characters")
            pasteAction(text)
        case .success:
            DebugLog.log("[Voice] empty transcription, nothing to paste")
        case .failure(let error):
            DebugLog.log("[Voice] transcription failed: \(error)")
        }
        toIdle()
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
        }
    }

    private func toIdle() {
        state = .idle
        activityModel.phase = .idle
        maxDurationTask?.cancel()
        maxDurationTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
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
