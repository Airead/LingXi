import AVFoundation
import Foundation
import Testing
@testable import LingXi

// MARK: - Fakes

private final class FakeSession: SpeechTranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _appendCount = 0
    private var _cancelled = false
    private var finishContinuation: CheckedContinuation<String, Error>?
    private var storedManualResult: Result<String, Error>?

    private let manualFinish: Bool
    private let finishResult: Result<String, Error>

    init(finishResult: Result<String, Error> = .success("hello"), manualFinish: Bool = false) {
        self.finishResult = finishResult
        self.manualFinish = manualFinish
    }

    var cancelled: Bool { lock.withLock { _cancelled } }
    var appendCount: Int { lock.withLock { _appendCount } }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { _appendCount += 1 }
    }

    func finish() async throws -> String {
        if !manualFinish {
            if lock.withLock({ _cancelled }) { throw CancellationError() }
            return try finishResult.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<String, Error>? = lock.withLock {
                if _cancelled { return .failure(CancellationError()) }
                if let stored = storedManualResult { return stored }
                finishContinuation = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    /// Completes a manual-mode finish(). No effect if already cancelled.
    func completeFinish(_ result: Result<String, Error>) {
        let pending: CheckedContinuation<String, Error>? = lock.withLock {
            let pending = finishContinuation
            finishContinuation = nil
            if pending == nil { storedManualResult = result }
            return pending
        }
        pending?.resume(with: result)
    }

    nonisolated func cancel() {
        let pending: CheckedContinuation<String, Error>? = lock.withLock {
            _cancelled = true
            let pending = finishContinuation
            finishContinuation = nil
            return pending
        }
        pending?.resume(throwing: CancellationError())
    }
}

private final class FakeTranscriber: SpeechTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingGate: CheckedContinuation<Void, Never>?
    private var gateReleased = false

    private let session: FakeSession
    private let gated: Bool
    private let makeSessionError: Error?

    init(session: FakeSession, gated: Bool = false, makeSessionError: Error? = nil) {
        self.session = session
        self.gated = gated
        self.makeSessionError = makeSessionError
    }

    func makeSession(language: VoiceLanguage) async throws -> any SpeechTranscriptionSession {
        if gated {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    if gateReleased { return true }
                    pendingGate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if let makeSessionError { throw makeSessionError }
        return session
    }

    func releaseGate() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            gateReleased = true
            let pending = pendingGate
            pendingGate = nil
            return pending
        }
        pending?.resume()
    }
}

private actor FakeRecorder: AudioRecording {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var startError: Error?

    func setStartError(_ error: Error?) { startError = error }

    func start(
        sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws {
        if let startError { throw startError }
        startCount += 1
    }

    func stop() { stopCount += 1 }
}

@MainActor
private final class PasteSpy {
    var pasted: [String] = []
}

// MARK: - Harness

@MainActor
private struct Harness {
    let settings: AppSettings
    let activity = VoiceActivityModel()
    let recorder = FakeRecorder()
    let transcriber: FakeTranscriber
    let spy = PasteSpy()
    let controller: VoiceInputController

    init(
        session: FakeSession,
        gated: Bool = false,
        timing: VoiceInputTiming = VoiceInputTiming(minHold: .zero)
    ) {
        let defaults = UserDefaults(suiteName: "io.github.airead.lingxi.test.\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
        settings.voiceInputEnabled = true
        transcriber = FakeTranscriber(session: session, gated: gated)

        let transcriber = self.transcriber
        let spy = self.spy
        controller = VoiceInputController(
            settings: settings,
            activityModel: activity,
            recorder: recorder,
            transcriberFactory: { _ in transcriber },
            pasteAction: { spy.pasted.append($0) },
            ensureMicrophonePermission: {},
            timing: timing
        )
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

// MARK: - Controller tests

@MainActor
struct VoiceInputControllerTests {

    @Test func normalFlowPastesTranscription() async {
        let session = FakeSession(finishResult: .success("hello"))
        let h = Harness(session: session)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.spy.pasted == ["hello"] })
        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(await h.recorder.stopCount >= 1)
    }

    @Test func releaseBeforeEngineReadyStillTranscribes() async {
        let session = FakeSession(finishResult: .success("hello"))
        let h = Harness(session: session, gated: true)

        h.controller.fnDown()
        // Engine startup is gated: release Fn before the session exists.
        h.controller.fnUp()
        #expect(h.activity.phase == .recording)
        #expect(await h.recorder.startCount == 0)

        h.transcriber.releaseGate()
        #expect(await waitUntil { h.spy.pasted == ["hello"] })
        #expect(h.activity.phase == .idle)
    }

    @Test func shortPressCancels() async {
        let session = FakeSession(finishResult: .success("hello"))
        let h = Harness(session: session, timing: VoiceInputTiming(minHold: .seconds(10)))

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        try? await Task.sleep(for: .milliseconds(20))
        h.controller.fnUp()

        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(session.cancelled)
        #expect(h.spy.pasted.isEmpty)
    }

    @Test func fnDownIgnoredWhileTranscribing() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(session: session)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.activity.phase == .transcribing })

        // Busy: a second press must not start a new session.
        h.controller.fnDown()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await h.recorder.startCount == 1)
        #expect(h.activity.phase == .transcribing)

        session.completeFinish(.success("x"))
        #expect(await waitUntil { h.spy.pasted == ["x"] })
        #expect(h.activity.phase == .idle)
    }

    @Test func transcriptionFailureReturnsToIdle() async {
        let session = FakeSession(finishResult: .failure(TranscriptionError.invalidResponse))
        let h = Harness(session: session)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(h.spy.pasted.isEmpty)
    }

    @Test func emptyTranscriptionNotPasted() async {
        let session = FakeSession(finishResult: .success(""))
        let h = Harness(session: session)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(h.spy.pasted.isEmpty)
    }

    @Test func engineStartFailureReturnsToIdle() async {
        let session = FakeSession()
        let h = Harness(session: session)
        await h.recorder.setStartError(AudioRecorderError.noInputDevice)

        h.controller.fnDown()
        #expect(await waitUntil { h.activity.phase == .idle })
        // The already-created session must be cleaned up.
        #expect(session.cancelled)
        #expect(h.spy.pasted.isEmpty)
    }

    @Test func interruptedDuringStartingCancels() async {
        let session = FakeSession()
        let h = Harness(session: session, gated: true)

        h.controller.fnDown()
        h.controller.fnInterrupted()
        h.transcriber.releaseGate()

        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(session.cancelled)
        #expect(h.spy.pasted.isEmpty)
    }

    @Test func interruptedDuringRecordingCancels() async {
        let session = FakeSession()
        let h = Harness(session: session)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        try? await Task.sleep(for: .milliseconds(20))
        h.controller.fnInterrupted()

        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(session.cancelled)
        #expect(h.spy.pasted.isEmpty)
    }

    @Test func maxDurationAutoTranscribes() async {
        let session = FakeSession(finishResult: .success("hello"))
        let h = Harness(
            session: session,
            timing: VoiceInputTiming(minHold: .zero, maxRecording: .milliseconds(30))
        )

        h.controller.fnDown()
        // Never release Fn: the max-duration timer must stop and transcribe.
        #expect(await waitUntil { h.spy.pasted == ["hello"] })
        #expect(h.activity.phase == .idle)
    }

    @Test func watchdogCancelsStuckTranscriptionAndDiscardsLateResult() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(
            session: session,
            timing: VoiceInputTiming(minHold: .zero, transcribeTimeout: .milliseconds(30))
        )

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.activity.phase == .transcribing })

        // The transcription never completes; the watchdog must recover.
        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(session.cancelled)

        // A late result from the abandoned session must be discarded.
        session.completeFinish(.success("late"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.spy.pasted.isEmpty)
        #expect(h.activity.phase == .idle)
    }

    @Test func disabledSettingIgnoresFnDown() async {
        let session = FakeSession()
        let h = Harness(session: session)
        h.settings.voiceInputEnabled = false

        h.controller.fnDown()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await h.recorder.startCount == 0)
        #expect(h.activity.phase == .idle)
    }
}

// MARK: - Fn transition pure function

struct FnKeyTransitionTests {
    private let fnKeycode: UInt16 = 63
    private let fnFlag = VoiceKeyMonitor.fnFlagMask

    @Test func detectsPress() {
        #expect(VoiceKeyMonitor.fnTransition(keycode: fnKeycode, flags: fnFlag, wasDown: false) == .pressed)
    }

    @Test func detectsRelease() {
        #expect(VoiceKeyMonitor.fnTransition(keycode: fnKeycode, flags: 0, wasDown: true) == .released)
    }

    @Test func noTransitionWhenStateUnchanged() {
        #expect(VoiceKeyMonitor.fnTransition(keycode: fnKeycode, flags: fnFlag, wasDown: true) == nil)
        #expect(VoiceKeyMonitor.fnTransition(keycode: fnKeycode, flags: 0, wasDown: false) == nil)
    }

    @Test func ignoresOtherKeycodes() {
        // Arrow keys etc. carry the Fn flag bit but are not the Fn key.
        #expect(VoiceKeyMonitor.fnTransition(keycode: 123, flags: fnFlag, wasDown: false) == nil)
    }
}

// MARK: - Voice settings persistence

@MainActor
struct VoiceSettingsPersistenceTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "io.github.airead.lingxi.test.\(UUID().uuidString)")!
    }

    @Test func defaults() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.voiceInputEnabled == false)
        #expect(settings.voiceBackend == .apple)
        #expect(settings.voiceAPIBaseURL == "https://api.openai.com/v1")
        #expect(settings.voiceAPIKey == "")
        #expect(settings.voiceAPIModel == "whisper-1")
        #expect(settings.voiceLanguage == .auto)
    }

    @Test func roundTrip() {
        let defaults = makeDefaults()
        let settings1 = AppSettings(defaults: defaults)
        settings1.voiceInputEnabled = true
        settings1.voiceBackend = .whisperAPI
        settings1.voiceAPIBaseURL = "https://api.groq.com/openai/v1"
        settings1.voiceAPIKey = "gsk_test"
        settings1.voiceAPIModel = "whisper-large-v3"
        settings1.voiceLanguage = .chinese

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.voiceInputEnabled == true)
        #expect(settings2.voiceBackend == .whisperAPI)
        #expect(settings2.voiceAPIBaseURL == "https://api.groq.com/openai/v1")
        #expect(settings2.voiceAPIKey == "gsk_test")
        #expect(settings2.voiceAPIModel == "whisper-large-v3")
        #expect(settings2.voiceLanguage == .chinese)
    }

    @Test func rejectsEmptyBaseURLAndModel() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.voiceAPIBaseURL = "  "
        #expect(settings.voiceAPIBaseURL == "https://api.openai.com/v1")
        settings.voiceAPIModel = ""
        #expect(settings.voiceAPIModel == "whisper-1")
    }
}
