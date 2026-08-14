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
    private var partialHandler: (@Sendable (String) -> Void)?

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

    nonisolated func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { partialHandler = handler }
    }

    /// Fires the registered partial handler, as the recognizer would.
    func emitPartial(_ text: String) {
        let handler = lock.withLock { partialHandler }
        handler?(text)
    }

    var hasPartialHandler: Bool { lock.withLock { partialHandler != nil } }

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

private final class FakeEnhancer: TextEnhancer, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var storedManualResult: Result<String, Error>?
    private var _requests: [String] = []

    private let manual: Bool
    private let result: Result<String, Error>

    init(result: Result<String, Error> = .success("enhanced"), manual: Bool = false) {
        self.result = result
        self.manual = manual
    }

    var requests: [String] { lock.withLock { _requests } }

    func enhance(_ text: String) async throws -> String {
        lock.withLock { _requests.append(text) }
        if !manual { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { newContinuation in
                let immediate: Result<String, Error>? = lock.withLock {
                    if let stored = storedManualResult { return stored }
                    continuation = newContinuation
                    return nil
                }
                if let immediate { newContinuation.resume(with: immediate) }
            }
        } onCancel: {
            let pending: CheckedContinuation<String, Error>? = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(throwing: CancellationError())
        }
    }

    /// Completes a manual-mode enhance(). No effect if already cancelled.
    func complete(_ result: Result<String, Error>) {
        let pending: CheckedContinuation<String, Error>? = lock.withLock {
            let pending = continuation
            continuation = nil
            if pending == nil { storedManualResult = result }
            return pending
        }
        pending?.resume(with: result)
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

@MainActor
private final class FakePreviewPresenter: VoicePreviewPresenting {
    private(set) var shown: [(text: String, original: String?)] = []
    private(set) var closeCount = 0
    private var onConfirm: (@MainActor (String) -> Void)?
    private var onCancel: (@MainActor () -> Void)?

    func show(
        text: String,
        original: String?,
        onConfirm: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        shown.append((text, original))
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    func close() {
        closeCount += 1
    }

    func simulateConfirm(_ text: String) { onConfirm?(text) }
    func simulateCancel() { onCancel?() }
}

@MainActor
private final class FakeHUDPresenter: VoiceHUDPresenting {
    private(set) var showCount = 0
    private(set) var hideCount = 0

    func show() { showCount += 1 }
    func hide() { hideCount += 1 }
}

// MARK: - Harness

@MainActor
private struct Harness {
    let settings: AppSettings
    let activity = VoiceActivityModel()
    let recorder = FakeRecorder()
    let transcriber: FakeTranscriber
    let enhancer: FakeEnhancer
    let preview = FakePreviewPresenter()
    let hud = FakeHUDPresenter()
    let spy = PasteSpy()
    let controller: VoiceInputController

    init(
        session: FakeSession,
        gated: Bool = false,
        enhancer: FakeEnhancer = FakeEnhancer(),
        enhanceEnabled: Bool = false,
        previewEnabled: Bool = false,
        hudEnabled: Bool = false,
        timing: VoiceInputTiming = VoiceInputTiming(minHold: .zero)
    ) {
        let defaults = UserDefaults(suiteName: "io.github.airead.lingxi.test.\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
        settings.voiceInputEnabled = true
        settings.voiceEnhanceEnabled = enhanceEnabled
        settings.voicePreviewEnabled = previewEnabled
        settings.voiceHUDEnabled = hudEnabled
        transcriber = FakeTranscriber(session: session, gated: gated)
        self.enhancer = enhancer

        let transcriber = self.transcriber
        let spy = self.spy
        controller = VoiceInputController(
            settings: settings,
            activityModel: activity,
            recorder: recorder,
            transcriberFactory: { _ in transcriber },
            enhancerFactory: { _ in enhancer },
            pasteAction: { spy.pasted.append($0) },
            ensureMicrophonePermission: {},
            previewPresenter: preview,
            hudPresenter: hud,
            frontmostAppProvider: { nil },
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

    @Test func enhanceSuccessPastesEnhancedText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.spy.pasted == ["polished"] })
        #expect(h.activity.phase == .idle)
        #expect(enhancer.requests == ["raw"])
    }

    @Test func enhanceFailureFallsBackToOriginal() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .failure(TranscriptionError.invalidResponse))
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.spy.pasted == ["raw"] })
        #expect(h.activity.phase == .idle)
    }

    @Test func enhanceEmptyResultFallsBackToOriginal() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success(""))
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.spy.pasted == ["raw"] })
        #expect(h.activity.phase == .idle)
    }

    @Test func enhanceDisabledPastesRawText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: false)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.spy.pasted == ["raw"] })
        #expect(enhancer.requests.isEmpty)
    }

    @Test func enhanceWatchdogFallsBackAndDiscardsLateResult() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(manual: true)
        let h = Harness(
            session: session,
            enhancer: enhancer,
            enhanceEnabled: true,
            timing: VoiceInputTiming(minHold: .zero, enhanceTimeout: .milliseconds(30))
        )

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.activity.phase == .enhancing })

        // The enhancement never completes; the watchdog must degrade to raw.
        #expect(await waitUntil { h.spy.pasted == ["raw"] })
        #expect(h.activity.phase == .idle)

        // A late result from the abandoned enhancement must be discarded.
        enhancer.complete(.success("late"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.spy.pasted == ["raw"])
        #expect(h.activity.phase == .idle)
    }

    @Test func fnDownIgnoredWhileEnhancing() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(manual: true)
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.activity.phase == .enhancing })

        // Busy: a second press must not start a new session.
        h.controller.fnDown()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await h.recorder.startCount == 1)
        #expect(h.activity.phase == .enhancing)

        enhancer.complete(.success("polished"))
        #expect(await waitUntil { h.spy.pasted == ["polished"] })
        #expect(h.activity.phase == .idle)
    }

    @Test func disablingVoiceInputAbortsEnhancement() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(manual: true)
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true)
        h.controller.applySettings()

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.activity.phase == .enhancing })

        h.settings.voiceInputEnabled = false
        h.controller.applySettings()

        #expect(await waitUntil { h.activity.phase == .idle })
        enhancer.complete(.success("late"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.spy.pasted.isEmpty)
    }

    @Test func previewConfirmPastesEditedText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.preview.shown.count == 1 })
        #expect(h.preview.shown[0].text == "raw")
        #expect(h.preview.shown[0].original == nil)
        #expect(h.spy.pasted.isEmpty)

        // The user edits the text in the panel before confirming.
        h.preview.simulateConfirm("edited")
        #expect(await waitUntil { h.spy.pasted == ["edited"] })
        #expect(h.activity.phase == .idle)
        #expect(h.preview.closeCount >= 1)
    }

    @Test func previewCancelDiscards() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 1 })

        h.preview.simulateCancel()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(h.spy.pasted.isEmpty)
        #expect(h.activity.phase == .idle)
    }

    @Test func previewShowsOriginalAlongsideEnhancedText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.preview.shown.count == 1 })
        #expect(h.preview.shown[0].text == "polished")
        #expect(h.preview.shown[0].original == "raw")
    }

    @Test func enhanceFailureWithPreviewShowsOriginalText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .failure(TranscriptionError.invalidResponse))
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.preview.shown.count == 1 })
        #expect(h.preview.shown[0].text == "raw")
        #expect(h.preview.shown[0].original == nil)
    }

    @Test func fnDownDuringPreviewStartsNewSession() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 1 })

        // A new press discards the pending preview and records again.
        h.controller.fnDown()
        #expect(h.preview.closeCount >= 1)
        #expect(await waitUntil { await h.recorder.startCount == 2 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 2 })

        // The first preview's confirm is stale and must be discarded.
        h.preview.simulateConfirm("second")
        #expect(await waitUntil { h.spy.pasted == ["second"] })
    }

    @Test func staleConfirmAfterCancelIsDiscarded() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 1 })

        h.preview.simulateCancel()
        #expect(h.activity.phase == .idle)

        // Confirm arriving after cancel must not paste.
        h.preview.simulateConfirm("late")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(h.spy.pasted.isEmpty)
    }

    @Test func emptyPreviewConfirmPastesNothing() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 1 })

        h.preview.simulateConfirm("")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(h.spy.pasted.isEmpty)
        #expect(h.activity.phase == .idle)
    }

    @Test func hudShownWhileRecordingAndHiddenWhenIdle() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(session: session, hudEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { h.hud.showCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.activity.phase == .transcribing })
        #expect(h.hud.hideCount == 0)

        session.completeFinish(.success("x"))
        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(h.hud.hideCount == 1)
    }

    @Test func hudDisabledNeverShows() async {
        let session = FakeSession(finishResult: .success("hello"))
        let h = Harness(session: session, hudEnabled: false)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.spy.pasted == ["hello"] })

        #expect(h.hud.showCount == 0)
        #expect(session.hasPartialHandler == false)
    }

    @Test func partialTextFlowsToActivityModelAndResetsOnIdle() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(session: session, hudEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        #expect(await waitUntil { session.hasPartialHandler })

        session.emitPartial("hello wor")
        #expect(await waitUntil { h.activity.partialText == "hello wor" })

        h.controller.fnUp()
        session.completeFinish(.success("hello world"))
        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(h.activity.partialText == "")
        #expect(h.activity.level == 0)
    }

    @Test func stalePartialAfterCancelIsDiscarded() async {
        let session = FakeSession(finishResult: .success("hello"))
        let h = Harness(session: session, hudEnabled: true, timing: VoiceInputTiming(minHold: .seconds(10)))

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp() // short press cancels and bumps generation
        #expect(await waitUntil { h.activity.phase == .idle })

        session.emitPartial("stale")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.activity.partialText == "")
    }

    @Test func hudHiddenWhenPreviewOpens() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true, hudEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { h.hud.showCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.preview.shown.count == 1 })
        #expect(h.hud.hideCount == 1)
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
        #expect(settings.voiceASRProviders.isEmpty)
        #expect(settings.voiceASRSelection == .apple)
        #expect(settings.voiceLLMProviders.isEmpty)
        #expect(settings.voiceLLMSelection == LLMSelection(provider: "", model: ""))
        #expect(settings.voiceLanguage == .auto)
        #expect(settings.voiceEnhanceEnabled == false)
        #expect(settings.voiceEnhancePrompt == LLMEnhancerConfiguration.defaultSystemPrompt)
        #expect(settings.voicePreviewEnabled == false)
        #expect(settings.voiceHUDEnabled == true)
    }

    @Test func roundTrip() {
        let defaults = makeDefaults()
        let groq = VoiceProvider(
            name: "groq", baseURL: "https://api.groq.com/openai/v1",
            apiKey: "gsk_test", models: ["whisper-large-v3", "whisper-large-v3-turbo"]
        )
        let ollama = VoiceProvider(
            name: "ollama", baseURL: "http://localhost:11434/v1",
            apiKey: "", models: ["qwen3"]
        )

        let settings1 = AppSettings(defaults: defaults)
        settings1.voiceInputEnabled = true
        settings1.voiceASRProviders = [groq]
        settings1.voiceASRSelection = .remote(provider: "groq", model: "whisper-large-v3")
        settings1.voiceLLMProviders = [ollama]
        settings1.voiceLLMSelection = LLMSelection(provider: "ollama", model: "qwen3")
        settings1.voiceLanguage = .chinese
        settings1.voiceEnhanceEnabled = true
        settings1.voiceEnhancePrompt = "custom prompt"
        settings1.voicePreviewEnabled = true
        settings1.voiceHUDEnabled = false

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.voiceInputEnabled == true)
        #expect(settings2.voiceASRProviders == [groq])
        #expect(settings2.voiceASRSelection == .remote(provider: "groq", model: "whisper-large-v3"))
        #expect(settings2.voiceLLMProviders == [ollama])
        #expect(settings2.voiceLLMSelection == LLMSelection(provider: "ollama", model: "qwen3"))
        #expect(settings2.voiceLanguage == .chinese)
        #expect(settings2.voiceEnhanceEnabled == true)
        #expect(settings2.voiceEnhancePrompt == "custom prompt")
        #expect(settings2.voicePreviewEnabled == true)
        #expect(settings2.voiceHUDEnabled == false)
    }

    @Test func corruptProviderDataFallsBackToDefaults() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "io.github.airead.lingxi.voiceASRProviders")
        defaults.set(Data("not json".utf8), forKey: "io.github.airead.lingxi.voiceASRSelection")
        defaults.set(Data("not json".utf8), forKey: "io.github.airead.lingxi.voiceLLMProviders")
        defaults.set(Data("not json".utf8), forKey: "io.github.airead.lingxi.voiceLLMSelection")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceASRProviders.isEmpty)
        #expect(settings.voiceASRSelection == .apple)
        #expect(settings.voiceLLMProviders.isEmpty)
        #expect(settings.voiceLLMSelection == LLMSelection(provider: "", model: ""))
    }

    @Test func rejectsEmptyPrompt() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.voiceEnhancePrompt = "  "
        #expect(settings.voiceEnhancePrompt == LLMEnhancerConfiguration.defaultSystemPrompt)
    }
}
