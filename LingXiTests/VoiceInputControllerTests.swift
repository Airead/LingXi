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
    private var reContinuation: CheckedContinuation<String, Error>?
    private var storedReResult: Result<String, Error>?
    private var _wavRequests: [Data] = []
    /// Consumed in call order; the last one repeats.
    private var reResults: [Result<String, Error>]
    private let reManual: Bool

    private let session: FakeSession
    private let gated: Bool
    private let makeSessionError: Error?

    init(
        session: FakeSession,
        gated: Bool = false,
        makeSessionError: Error? = nil,
        reTranscribeResults: [Result<String, Error>] = [.success("re-transcribed")],
        reTranscribeManual: Bool = false
    ) {
        self.session = session
        self.gated = gated
        self.makeSessionError = makeSessionError
        self.reResults = reTranscribeResults
        self.reManual = reTranscribeManual
    }

    var wavRequests: [Data] { lock.withLock { _wavRequests } }

    func transcribe(wavData: Data, language: VoiceLanguage) async throws -> String {
        let result: Result<String, Error> = lock.withLock {
            _wavRequests.append(wavData)
            return reResults.count > 1 ? reResults.removeFirst() : reResults[0]
        }
        if !reManual { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { newContinuation in
                let immediate: Result<String, Error>? = lock.withLock {
                    if let stored = storedReResult { return stored }
                    reContinuation = newContinuation
                    return nil
                }
                if let immediate { newContinuation.resume(with: immediate) }
            }
        } onCancel: {
            let pending: CheckedContinuation<String, Error>? = lock.withLock {
                let pending = reContinuation
                reContinuation = nil
                return pending
            }
            pending?.resume(throwing: CancellationError())
        }
    }

    /// Completes a manual-mode transcribe(wavData:). No effect if cancelled.
    func completeReTranscribe(_ result: Result<String, Error>) {
        let pending: CheckedContinuation<String, Error>? = lock.withLock {
            let pending = reContinuation
            reContinuation = nil
            if pending == nil { storedReResult = result }
            return pending
        }
        pending?.resume(with: result)
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
    /// Consumed in call order; the last one repeats.
    private let results: [Result<String, Error>]

    init(result: Result<String, Error> = .success("enhanced"), manual: Bool = false) {
        self.results = [result]
        self.manual = manual
    }

    init(results: [Result<String, Error>]) {
        self.results = results
        self.manual = false
    }

    var requests: [String] { lock.withLock { _requests } }

    func enhance(_ text: String) async throws -> String {
        let result: Result<String, Error> = lock.withLock {
            _requests.append(text)
            return results[min(_requests.count - 1, results.count - 1)]
        }
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

/// Streaming enhancer with externally driven deltas and completion.
private final class StreamingFakeEnhancer: TextEnhancer, @unchecked Sendable {
    private let lock = NSLock()
    private var onDelta: (@Sendable (String) -> Void)?
    private var continuation: CheckedContinuation<String, Error>?
    private var storedResult: Result<String, Error>?
    private var _requests: [String] = []

    var requests: [String] { lock.withLock { _requests } }

    func enhance(_ text: String) async throws -> String {
        try await enhanceStream(text) { _ in }
    }

    func enhanceStream(
        _ text: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        lock.withLock {
            _requests.append(text)
            self.onDelta = onDelta
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { newContinuation in
                let immediate: Result<String, Error>? = lock.withLock {
                    if let stored = storedResult { return stored }
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

    func emitDelta(_ delta: String) {
        let handler = lock.withLock { onDelta }
        handler?(delta)
    }

    func finishStream(_ result: Result<String, Error>) {
        let pending: CheckedContinuation<String, Error>? = lock.withLock {
            let pending = continuation
            continuation = nil
            if pending == nil { storedResult = result }
            return pending
        }
        pending?.resume(with: result)
    }
}

private final class FakeRetainedAudio: AudioRetaining, @unchecked Sendable {
    private let lock = NSLock()
    private var _appendCount = 0
    private var _stopped = false
    let wav: Data

    init(wav: Data = Data("RIFF-fake".utf8)) { self.wav = wav }

    var appendCount: Int { lock.withLock { _appendCount } }
    var stopped: Bool { lock.withLock { _stopped } }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { _appendCount += 1 } }
    nonisolated func stopAccepting() { lock.withLock { _stopped = true } }
    func wavData() async throws -> Data { wav }
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
    var copied: [String] = []
}

@MainActor
private final class PromptSpy {
    var prompts: [String] = []
}

@MainActor
private final class RetainerSpy {
    var createdCount = 0
}

@MainActor
private final class FakePreviewPresenter: VoicePreviewPresenting {
    private(set) var shown: [(text: String, original: String?)] = []
    private(set) var setups: [VoicePreviewSetup] = []
    private(set) var asrResults: [(text: String, info: String)] = []
    private(set) var asrFailures: [String] = []
    private(set) var audioAvailable: [Data] = []
    private(set) var asrTranscribing: [String] = []
    private(set) var updates: [(text: String, original: String?, modeID: String, isCached: Bool)] = []
    private(set) var enhancingStates: [Bool] = []
    private(set) var deltas: [String] = []
    private(set) var systemPrompts: [String?] = []
    private(set) var closeCount = 0
    private var callbacks: VoicePreviewCallbacks?

    func show(setup: VoicePreviewSetup, callbacks: VoicePreviewCallbacks) {
        shown.append((setup.text, setup.original))
        setups.append(setup)
        self.callbacks = callbacks
    }

    func setASRResult(text: String, asrInfo: String) {
        asrResults.append((text, asrInfo))
    }

    func setASRFailed(message: String) {
        asrFailures.append(message)
    }

    func setAudioAvailable(wavData: Data) {
        audioAvailable.append(wavData)
    }

    func setASRTranscribing(info: String) {
        asrTranscribing.append(info)
    }

    func update(
        text: String,
        original: String?,
        currentModeID: String,
        currentLLM: LLMSelection?,
        isCached: Bool
    ) {
        updates.append((text, original, currentModeID, isCached))
    }

    func setEnhancing(_ enhancing: Bool) {
        enhancingStates.append(enhancing)
    }

    func appendEnhanceDelta(_ delta: String) {
        deltas.append(delta)
    }

    func setSystemPrompt(_ prompt: String?) {
        systemPrompts.append(prompt)
    }

    func close() {
        closeCount += 1
    }

    func simulateConfirm(_ text: String) { callbacks?.onConfirm(text) }
    func simulateCopy(_ text: String) { callbacks?.onCopy(text) }
    func simulateCancel() { callbacks?.onCancel() }
    func simulateModeSwitch(_ modeID: String) { callbacks?.onModeSwitch(modeID) }
    func simulateModelSwitch(_ selection: LLMSelection) { callbacks?.onModelSwitch(selection) }
    func simulateASRSwitch(_ selection: ASRSelection) { callbacks?.onASRSwitch(selection) }
    func simulateHistorySelect(_ token: UUID) { callbacks?.onHistorySelect(token) }
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
    let prompts = PromptSpy()
    let audioRetainer = FakeRetainedAudio()
    let retainerSpy = RetainerSpy()
    let history: ConversationHistory
    let controller: VoiceInputController

    init(
        session: FakeSession,
        gated: Bool = false,
        enhancer: FakeEnhancer = FakeEnhancer(),
        enhanceEnabled: Bool = false,
        previewEnabled: Bool = false,
        hudEnabled: Bool = false,
        historyEnabled: Bool = false,
        reTranscribeResults: [Result<String, Error>] = [.success("re-transcribed")],
        reTranscribeManual: Bool = false,
        streamingEnhancer: StreamingFakeEnhancer? = nil,
        timing: VoiceInputTiming = VoiceInputTiming(minHold: .zero)
    ) {
        let defaults = UserDefaults(suiteName: "io.github.airead.lingxi.test.\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
        settings.voiceInputEnabled = true
        settings.voiceEnhanceMode = enhanceEnabled ? "proofread" : EnhanceMode.offModeID
        settings.voicePreviewEnabled = previewEnabled
        settings.voiceHUDEnabled = hudEnabled
        settings.voiceHistoryEnabled = historyEnabled
        transcriber = FakeTranscriber(
            session: session,
            gated: gated,
            reTranscribeResults: reTranscribeResults,
            reTranscribeManual: reTranscribeManual
        )
        self.enhancer = enhancer
        history = ConversationHistory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-voice-history-\(UUID().uuidString)", isDirectory: true))

        let transcriber = self.transcriber
        let spy = self.spy
        let prompts = self.prompts
        let audioRetainer = self.audioRetainer
        let retainerSpy = self.retainerSpy
        controller = VoiceInputController(
            settings: settings,
            activityModel: activity,
            recorder: recorder,
            transcriberFactory: { _ in transcriber },
            enhancerFactory: { _, prompt in
                prompts.prompts.append(prompt)
                return streamingEnhancer ?? enhancer
            },
            enhancePromptProvider: { $0 == EnhanceMode.offModeID ? nil : "prompt-\($0)" },
            enhanceModesProvider: {
                [
                    EnhanceMode(id: "proofread", label: "纠错润色", order: 1, prompt: "p1"),
                    EnhanceMode(id: "translate_en", label: "翻译为英文", order: 2, prompt: "p2"),
                ]
            },
            audioRetainerFactory: {
                retainerSpy.createdCount += 1
                return audioRetainer
            },
            pasteAction: { spy.pasted.append($0) },
            copyAction: { spy.copied.append($0) },
            ensureMicrophonePermission: {},
            previewPresenter: preview,
            hudPresenter: hud,
            frontmostAppProvider: { nil },
            conversationHistory: history,
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

        // The panel opens in transcribing state, then the ASR result fills it.
        #expect(await waitUntil { h.preview.shown.count == 1 })
        #expect(h.preview.setups[0].isTranscribing == true)
        #expect(await waitUntil { h.preview.asrResults.count == 1 })
        #expect(h.preview.asrResults[0].text == "raw")
        // ASR info line carries the model name and a positive duration.
        #expect(h.preview.setups[0].asrInfo.hasPrefix("apple · "))
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
        #expect(await waitUntil { h.preview.asrResults.count == 1 })

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

        // The enhanced result arrives as an update to the open panel.
        #expect(await waitUntil { h.preview.updates.count == 1 })
        #expect(h.preview.updates[0].text == "polished")
        #expect(h.preview.updates[0].original == "raw")
        #expect(h.preview.asrResults[0].text == "raw")
    }

    @Test func enhanceFailureWithPreviewShowsOriginalText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .failure(TranscriptionError.invalidResponse))
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        // Degrade returns to the panel showing the ASR text.
        #expect(await waitUntil { h.preview.updates.count == 1 })
        #expect(h.preview.updates[0].text == "raw")
        #expect(h.preview.updates[0].original == nil)
        #expect(h.preview.closeCount == 0)
    }

    @Test func fnDownDuringPreviewStartsNewSession() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.asrResults.count == 1 })

        // A new press discards the pending preview and records again.
        h.controller.fnDown()
        #expect(h.preview.closeCount >= 1)
        #expect(await waitUntil { await h.recorder.startCount == 2 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.asrResults.count == 2 })

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
        #expect(await waitUntil { h.preview.asrResults.count == 1 })

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
        #expect(await waitUntil { h.preview.asrResults.count == 1 })

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

    // MARK: - Phase 3C: preview panel enhancements

    /// Runs one full recording session until the panel holds the ASR result.
    /// With enhancement on, callers should additionally wait for the
    /// enhancement update before interacting with the preview.
    private func runToPreview(_ h: Harness, expectedShown: Int = 1) async {
        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount >= expectedShown })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == expectedShown })
        #expect(await waitUntil { h.preview.asrResults.count == expectedShown })
    }

    @Test func commandReturnCopiesWithoutPasting() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)
        await runToPreview(h)

        h.preview.simulateCopy("copied text")
        #expect(await waitUntil { h.spy.copied == ["copied text"] })
        #expect(h.spy.pasted.isEmpty)
        #expect(h.activity.phase == .idle)
        #expect(h.preview.closeCount >= 1)
    }

    @Test func modeSwitchReEnhancesWithSessionASRText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(results: [.success("polished-1"), .success("polished-2")])
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true, previewEnabled: true)
        await runToPreview(h)
        #expect(await waitUntil { h.preview.updates.count == 1 })
        #expect(h.preview.updates[0].text == "polished-1")

        h.preview.simulateModeSwitch("translate_en")
        #expect(await waitUntil { h.preview.updates.count == 2 })
        // The re-enhancement runs on the raw ASR text, not the previous result.
        #expect(enhancer.requests == ["raw", "raw"])
        #expect(h.preview.updates[1].text == "polished-2")
        #expect(h.preview.updates[1].isCached == false)
        #expect(h.settings.voiceEnhanceMode == "translate_en")
        // Panel stays open the whole time.
        #expect(h.preview.closeCount == 0)
    }

    @Test func modeSwitchBackHitsCacheWithoutEnhancerCall() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(results: [.success("polished-1"), .success("polished-2")])
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true, previewEnabled: true)
        await runToPreview(h)
        #expect(await waitUntil { h.preview.updates.count == 1 })

        h.preview.simulateModeSwitch("translate_en")
        #expect(await waitUntil { h.preview.updates.count == 2 })

        h.preview.simulateModeSwitch("proofread")
        #expect(await waitUntil { h.preview.updates.count == 3 })
        #expect(h.preview.updates[2].text == "polished-1")
        #expect(h.preview.updates[2].isCached == true)
        #expect(enhancer.requests.count == 2)
    }

    @Test func modelSwitchReEnhancesAndPersistsSelection() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(results: [.success("polished-1"), .success("polished-2")])
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true, previewEnabled: true)
        h.settings.voiceLLMProviders = [
            VoiceProvider(name: "p1", baseURL: "http://x.test/v1", apiKey: "", models: ["m1", "m2"])
        ]
        h.settings.voiceLLMSelection = LLMSelection(provider: "p1", model: "m1")
        await runToPreview(h)
        #expect(await waitUntil { h.preview.updates.count == 1 })

        h.preview.simulateModelSwitch(LLMSelection(provider: "p1", model: "m2"))
        #expect(await waitUntil { h.preview.updates.count == 2 })
        #expect(h.preview.updates[1].text == "polished-2")
        #expect(enhancer.requests.count == 2)
        #expect(h.settings.voiceLLMSelection == LLMSelection(provider: "p1", model: "m2"))

        // Back to the first model: cached, no third request.
        h.preview.simulateModelSwitch(LLMSelection(provider: "p1", model: "m1"))
        #expect(await waitUntil { h.preview.updates.count == 3 })
        #expect(h.preview.updates[2].text == "polished-1")
        #expect(h.preview.updates[2].isCached == true)
        #expect(enhancer.requests.count == 2)
    }

    @Test func reEnhanceWatchdogReturnsToPanelWithASRText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(manual: true)
        let h = Harness(
            session: session,
            enhancer: enhancer,
            enhanceEnabled: false,
            previewEnabled: true,
            timing: VoiceInputTiming(minHold: .zero, enhanceTimeout: .milliseconds(30))
        )
        await runToPreview(h)
        #expect(h.preview.asrResults[0].text == "raw")

        // Switching modes starts a re-enhancement that never completes.
        h.preview.simulateModeSwitch("proofread")
        #expect(await waitUntil { h.preview.updates.count == 1 })
        // Watchdog degrades back to the panel showing the ASR text.
        #expect(h.preview.updates[0].text == "raw")
        #expect(h.preview.closeCount == 0)
        #expect(h.spy.pasted.isEmpty)

        // A late result from the abandoned re-enhancement must be discarded.
        enhancer.complete(.success("late"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.preview.updates.count == 1)
    }

    @Test func escDuringReEnhanceDiscardsAndIgnoresLateResult() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(manual: true)
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: false, previewEnabled: true)
        await runToPreview(h)

        h.preview.simulateModeSwitch("proofread")
        #expect(await waitUntil { h.preview.enhancingStates.last == true })

        h.preview.simulateCancel()
        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(h.preview.closeCount >= 1)

        enhancer.complete(.success("late"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.spy.pasted.isEmpty)
        #expect(h.preview.updates.isEmpty)
        #expect(h.activity.phase == .idle)
    }

    @Test func fnDownDuringReEnhanceStartsNewSession() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(manual: true)
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: false, previewEnabled: true)
        await runToPreview(h)

        h.preview.simulateModeSwitch("proofread")
        #expect(await waitUntil { h.preview.enhancingStates.last == true })

        // A new press discards the re-enhancing preview and records again.
        h.controller.fnDown()
        #expect(h.preview.closeCount >= 1)
        #expect(await waitUntil { await h.recorder.startCount == 2 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 2 })
    }

    @Test func previewHistoryCappedAtTen() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)

        for i in 1...12 {
            await runToPreview(h, expectedShown: i)
            h.preview.simulateConfirm("final-\(i)")
            #expect(await waitUntil { h.activity.phase == .idle })
        }
        #expect(h.preview.setups.last?.history.count == 10)
    }

    @Test func showLastPreviewReopensMostRecentEntry() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)
        await runToPreview(h)
        h.preview.simulateConfirm("final text")
        #expect(await waitUntil { h.spy.pasted == ["final text"] })

        h.controller.showLastPreview()
        #expect(h.preview.shown.count == 2)
        #expect(h.preview.shown[1].text == "final text")

        // The recalled preview is fully functional: confirm pastes again.
        h.preview.simulateConfirm("again")
        #expect(await waitUntil { h.spy.pasted == ["final text", "again"] })
    }

    @Test func showLastPreviewIgnoredWithoutHistoryOrWhileBusy() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)

        // No history yet: nothing happens.
        h.controller.showLastPreview()
        #expect(h.preview.shown.isEmpty)

        // While previewing: not idle, so the call is ignored.
        await runToPreview(h)
        h.controller.showLastPreview()
        #expect(h.preview.shown.count == 1)
    }

    // MARK: - Retained audio

    @Test func previewSessionRetainsAudioAndPanelReceivesWav() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)
        await runToPreview(h)

        #expect(h.retainerSpy.createdCount == 1)
        #expect(h.audioRetainer.stopped)
        #expect(await waitUntil { h.preview.audioAvailable == [h.audioRetainer.wav] })
    }

    @Test func audioRetainerNotCreatedWithoutPreview() async {
        let session = FakeSession(finishResult: .success("hello"))
        let h = Harness(session: session)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.spy.pasted == ["hello"] })

        #expect(h.retainerSpy.createdCount == 0)
        #expect(h.preview.audioAvailable.isEmpty)
    }

    @Test func failedTranscriptionSessionKeepsAudio() async {
        let session = FakeSession(finishResult: .failure(TranscriptionError.invalidResponse))
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.asrFailures.count == 1 })

        // The failure session still owns the audio: the WAV reaches the panel.
        #expect(await waitUntil { h.preview.audioAvailable.count == 1 })
    }

    @Test func recalledHistoryEntryHasNoAudio() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)
        await runToPreview(h)
        #expect(await waitUntil { h.preview.audioAvailable.count == 1 })
        h.preview.simulateConfirm("raw")
        #expect(await waitUntil { h.activity.phase == .idle })

        // The recalled panel must not receive the previous recording's audio.
        h.controller.showLastPreview()
        #expect(h.preview.shown.count == 2)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.preview.audioAvailable.count == 1)
    }

    // MARK: - ASR switch & re-transcribe

    private let remoteASR = ASRSelection.remote(provider: "groq", model: "m1")

    private func addASRProvider(_ h: Harness) {
        h.settings.voiceASRProviders = [
            VoiceProvider(name: "groq", baseURL: "http://x.test/v1", apiKey: "k", models: ["m1"])
        ]
    }

    @Test func asrSwitchReTranscribesClearsCacheAndPersists() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(results: [.success("polished-1"), .success("polished-2")])
        let h = Harness(
            session: session, enhancer: enhancer,
            enhanceEnabled: true, previewEnabled: true, historyEnabled: true
        )
        addASRProvider(h)
        await runToPreview(h)
        #expect(await waitUntil { h.preview.updates.count == 1 })
        #expect(h.preview.updates[0].text == "polished-1")

        h.preview.simulateASRSwitch(remoteASR)
        // The ASR area goes back to a progress state, then fills with the
        // re-transcription; the cache is stale so enhancement re-runs.
        #expect(await waitUntil { h.preview.asrTranscribing.count == 1 })
        #expect(await waitUntil { h.preview.asrResults.count == 2 })
        #expect(h.preview.asrResults[1].text == "re-transcribed")
        #expect(h.settings.voiceASRSelection == remoteASR)
        #expect(h.transcriber.wavRequests == [h.audioRetainer.wav])
        #expect(await waitUntil { h.preview.updates.count == 2 })
        #expect(h.preview.updates[1].text == "polished-2")
        #expect(enhancer.requests == ["raw", "re-transcribed"])
        #expect(h.preview.closeCount == 0)

        // The confirmed record carries the new ASR model.
        h.preview.simulateConfirm("final")
        #expect(await waitUntil { await h.history.readRecords().count == 1 })
        let record = await h.history.readRecords()[0]
        #expect(record.asrText == "re-transcribed")
        #expect(record.asrModel == "groq/m1")
    }

    @Test func asrSwitchToSameSelectionIsNoop() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)
        await runToPreview(h)

        h.preview.simulateASRSwitch(.apple)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.preview.asrTranscribing.isEmpty)
        #expect(h.transcriber.wavRequests.isEmpty)
    }

    @Test func asrSwitchFailureKeepsPreviousText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(
            session: session, previewEnabled: true,
            reTranscribeResults: [.failure(TranscriptionError.invalidResponse)]
        )
        addASRProvider(h)
        await runToPreview(h)

        h.preview.simulateASRSwitch(remoteASR)
        #expect(await waitUntil { h.preview.asrResults.count == 2 })
        #expect(h.preview.asrResults[1].text == "raw")
        #expect(h.preview.asrResults[1].info.contains("switch failed"))
        #expect(h.settings.voiceASRSelection == remoteASR)
        #expect(h.preview.closeCount == 0)

        // The panel is still functional: confirm pastes the previous text.
        h.preview.simulateConfirm("raw")
        #expect(await waitUntil { h.spy.pasted == ["raw"] })
    }

    @Test func asrSwitchDuringTranscribingOnlyPreselects() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(session: session, previewEnabled: true)
        addASRProvider(h)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 1 })

        h.preview.simulateASRSwitch(remoteASR)
        #expect(h.settings.voiceASRSelection == remoteASR)
        #expect(h.transcriber.wavRequests.isEmpty)
        #expect(h.preview.asrTranscribing.isEmpty)

        session.completeFinish(.success("raw"))
        #expect(await waitUntil { h.preview.asrResults.count == 1 })
    }

    @Test func escDuringReTranscribeDiscardsAndIgnoresLateResult() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true, reTranscribeManual: true)
        addASRProvider(h)
        await runToPreview(h)

        h.preview.simulateASRSwitch(remoteASR)
        #expect(await waitUntil { h.preview.asrTranscribing.count == 1 })

        h.preview.simulateCancel()
        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(h.preview.closeCount >= 1)

        h.transcriber.completeReTranscribe(.success("late"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.preview.asrResults.count == 1)
        #expect(h.spy.pasted.isEmpty)
    }

    @Test func fnDownDuringReTranscribeStartsNewSession() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true, reTranscribeManual: true)
        addASRProvider(h)
        await runToPreview(h)

        h.preview.simulateASRSwitch(remoteASR)
        #expect(await waitUntil { h.preview.asrTranscribing.count == 1 })

        h.controller.fnDown()
        #expect(h.preview.closeCount >= 1)
        #expect(await waitUntil { await h.recorder.startCount == 2 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 2 })
    }

    @Test func confirmDuringReTranscribePastesCurrentText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true, reTranscribeManual: true)
        addASRProvider(h)
        await runToPreview(h)

        h.preview.simulateASRSwitch(remoteASR)
        #expect(await waitUntil { h.preview.asrTranscribing.count == 1 })

        h.preview.simulateConfirm("typed")
        #expect(await waitUntil { h.spy.pasted == ["typed"] })
        #expect(h.activity.phase == .idle)

        // A late result must not resurrect anything.
        h.transcriber.completeReTranscribe(.success("late"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.preview.asrResults.count == 1)
    }

    @Test func reTranscribeWatchdogKeepsPreviousTextAndDiscardsLateResult() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(
            session: session, previewEnabled: true, reTranscribeManual: true,
            timing: VoiceInputTiming(minHold: .zero, transcribeTimeout: .milliseconds(30))
        )
        addASRProvider(h)
        await runToPreview(h)

        h.preview.simulateASRSwitch(remoteASR)
        #expect(await waitUntil { h.preview.asrTranscribing.count == 1 })

        // Watchdog restores the old text with a failure hint.
        #expect(await waitUntil { h.preview.asrResults.count == 2 })
        #expect(h.preview.asrResults[1].text == "raw")
        #expect(h.preview.asrResults[1].info.contains("switch failed"))
        #expect(h.preview.closeCount == 0)

        h.transcriber.completeReTranscribe(.success("late"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.preview.asrResults.count == 2)
    }

    @Test func modeSwitchDuringReTranscribeCancelsAndEnhancesOldText() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(
            session: session, enhancer: enhancer,
            enhanceEnabled: false, previewEnabled: true, reTranscribeManual: true
        )
        addASRProvider(h)
        await runToPreview(h)

        h.preview.simulateASRSwitch(remoteASR)
        #expect(await waitUntil { h.preview.asrTranscribing.count == 1 })

        // Switching modes interrupts the re-transcription and enhances the
        // previous ASR text.
        h.preview.simulateModeSwitch("proofread")
        #expect(await waitUntil { h.preview.updates.count == 1 })
        #expect(h.preview.updates[0].text == "polished")
        #expect(enhancer.requests == ["raw"])
        // The ASR area was restored before the enhancement started.
        #expect(h.preview.asrResults.count == 2)
        #expect(h.preview.asrResults[1].text == "raw")
    }

    @Test func failedTranscriptionRecoveredByASRSwitch() async {
        let session = FakeSession(finishResult: .failure(TranscriptionError.invalidResponse))
        let h = Harness(session: session, previewEnabled: true)
        addASRProvider(h)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.asrFailures.count == 1 })

        // Switching the ASR model re-transcribes the retained audio and
        // recovers the failed session.
        h.preview.simulateASRSwitch(remoteASR)
        #expect(await waitUntil { h.preview.asrResults.count == 1 })
        #expect(h.preview.asrResults[0].text == "re-transcribed")

        h.preview.simulateConfirm("re-transcribed")
        #expect(await waitUntil { h.spy.pasted == ["re-transcribed"] })

        // The recovered session became a preview-history entry.
        h.controller.showLastPreview()
        #expect(h.preview.shown.count == 2)
        #expect(h.preview.shown[1].text == "re-transcribed")
    }

    @Test func asrSwitchOnRecalledEntryOnlyPersistsSelection() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true)
        addASRProvider(h)
        await runToPreview(h)
        h.preview.simulateConfirm("raw")
        #expect(await waitUntil { h.activity.phase == .idle })

        h.controller.showLastPreview()
        #expect(h.preview.shown.count == 2)
        h.preview.simulateASRSwitch(remoteASR)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.settings.voiceASRSelection == remoteASR)
        #expect(h.transcriber.wavRequests.isEmpty)
        #expect(h.preview.asrTranscribing.isEmpty)
    }

    // MARK: - System prompt viewer

    @Test func panelReceivesFullPromptIncludingInjection() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(
            session: session, enhancer: enhancer,
            enhanceEnabled: true, previewEnabled: true, historyEnabled: true
        )
        // A confirmed correction from an earlier session gets injected.
        await h.history.record(ConversationRecord(
            timestamp: ConversationRecord.makeTimestamp(),
            asrText: "erly", enhancedText: nil, finalText: "early",
            enhanceMode: "proofread", previewEnabled: true,
            asrModel: "apple", llmModel: "", userCorrected: true, audioDuration: 1
        ))
        await runToPreview(h)
        #expect(await waitUntil { h.preview.updates.count == 1 })

        let prompt = try? #require(h.preview.systemPrompts.last ?? nil)
        #expect(prompt?.hasPrefix("prompt-proofread") == true)
        #expect(prompt?.contains(ConversationHistory.injectionHeader) == true)
        #expect(prompt?.contains("erly → early") == true)
    }

    @Test func cacheHitShowsThePromptItWasEnhancedWith() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(results: [.success("polished-1"), .success("polished-2")])
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true, previewEnabled: true)
        await runToPreview(h)
        #expect(await waitUntil { h.preview.updates.count == 1 })
        #expect(h.preview.systemPrompts.last == "prompt-proofread")

        h.preview.simulateModeSwitch("translate_en")
        #expect(await waitUntil { h.preview.updates.count == 2 })
        #expect(h.preview.systemPrompts.last == "prompt-translate_en")

        // Back to the cached combination: its original prompt is restored.
        h.preview.simulateModeSwitch("proofread")
        #expect(await waitUntil { h.preview.updates.count == 3 })
        #expect(h.preview.updates[2].isCached == true)
        #expect(h.preview.systemPrompts.last == "prompt-proofread")
        #expect(enhancer.requests.count == 2)
    }

    @Test func modeOffClearsSystemPrompt() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true, previewEnabled: true)
        await runToPreview(h)
        #expect(await waitUntil { h.preview.updates.count == 1 })

        h.preview.simulateModeSwitch(EnhanceMode.offModeID)
        #expect(await waitUntil { h.preview.updates.count == 2 })
        #expect(h.preview.systemPrompts.last == .some(nil))
    }

    // MARK: - Streaming enhancement

    @Test func streamingDeltasReachPanelAndCompleteOnce() async {
        let session = FakeSession(finishResult: .success("raw"))
        let streaming = StreamingFakeEnhancer()
        let h = Harness(
            session: session, enhanceEnabled: true, previewEnabled: true,
            streamingEnhancer: streaming
        )
        await runToPreview(h)
        #expect(await waitUntil { streaming.requests == ["raw"] })

        streaming.emitDelta("pol")
        streaming.emitDelta("ished")
        #expect(await waitUntil { h.preview.deltas == ["pol", "ished"] })
        #expect(h.preview.updates.isEmpty)

        streaming.finishStream(.success("polished"))
        #expect(await waitUntil { h.preview.updates.count == 1 })
        #expect(h.preview.updates[0].text == "polished")
        // The panel's update()/apply() ends the enhancing display; no
        // explicit setEnhancing(false) call is expected.
        #expect(h.preview.enhancingStates == [true])
    }

    @Test func lateDeltaAfterCancelIsDiscarded() async {
        let session = FakeSession(finishResult: .success("raw"))
        let streaming = StreamingFakeEnhancer()
        let h = Harness(
            session: session, enhanceEnabled: true, previewEnabled: true,
            streamingEnhancer: streaming
        )
        await runToPreview(h)
        #expect(await waitUntil { streaming.requests == ["raw"] })
        streaming.emitDelta("pol")
        #expect(await waitUntil { h.preview.deltas == ["pol"] })

        h.preview.simulateCancel()
        #expect(await waitUntil { h.activity.phase == .idle })

        streaming.emitDelta("late")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.preview.deltas == ["pol"])
    }

    @Test func liveStreamKeepsEnhanceWatchdogAlive() async {
        let session = FakeSession(finishResult: .success("raw"))
        let streaming = StreamingFakeEnhancer()
        let h = Harness(
            session: session, enhanceEnabled: true, previewEnabled: true,
            streamingEnhancer: streaming,
            timing: VoiceInputTiming(minHold: .zero, enhanceTimeout: .milliseconds(80))
        )
        await runToPreview(h)
        #expect(await waitUntil { streaming.requests == ["raw"] })

        // Keep emitting deltas past the idle timeout: no degrade.
        for i in 0..<6 {
            streaming.emitDelta("d\(i)")
            try? await Task.sleep(for: .milliseconds(30))
        }
        #expect(h.preview.updates.isEmpty)

        streaming.finishStream(.success("full"))
        #expect(await waitUntil { h.preview.updates.count == 1 })
        #expect(h.preview.updates[0].text == "full")
    }

    @Test func stalledStreamDegradesToASRTextAfterIdleTimeout() async {
        let session = FakeSession(finishResult: .success("raw"))
        let streaming = StreamingFakeEnhancer()
        let h = Harness(
            session: session, enhanceEnabled: true, previewEnabled: true,
            streamingEnhancer: streaming,
            timing: VoiceInputTiming(minHold: .zero, enhanceTimeout: .milliseconds(50))
        )
        await runToPreview(h)
        #expect(await waitUntil { streaming.requests == ["raw"] })
        streaming.emitDelta("pol")
        // …then the stream stalls: the watchdog degrades to the ASR text.
        #expect(await waitUntil { h.preview.updates.count == 1 })
        #expect(h.preview.updates[0].text == "raw")
        #expect(h.preview.updates[0].original == nil)
        #expect(h.preview.closeCount == 0)
    }

    @Test func directPastePathProducesNoDeltas() async {
        let session = FakeSession(finishResult: .success("raw"))
        let streaming = StreamingFakeEnhancer()
        let h = Harness(session: session, enhanceEnabled: true, streamingEnhancer: streaming)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { streaming.requests == ["raw"] })

        streaming.finishStream(.success("polished"))
        #expect(await waitUntil { h.spy.pasted == ["polished"] })
        #expect(h.preview.deltas.isEmpty)
    }

    // MARK: - Phase 3D: conversation history

    @Test func previewConfirmRecordsHistoryWithCorrectionFlag() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(
            session: session, enhancer: enhancer,
            enhanceEnabled: true, previewEnabled: true, historyEnabled: true
        )
        await runToPreview(h)
        #expect(await waitUntil { h.preview.updates.count == 1 })

        h.preview.simulateConfirm("edited")
        #expect(await waitUntil { await h.history.readRecords().count == 1 })
        let record = await h.history.readRecords()[0]
        #expect(record.asrText == "raw")
        #expect(record.enhancedText == "polished")
        #expect(record.finalText == "edited")
        #expect(record.enhanceMode == "proofread")
        #expect(record.previewEnabled == true)
        #expect(record.userCorrected == true)
        #expect(record.asrModel == "apple")
    }

    @Test func previewConfirmUneditedRecordsNoCorrection() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(
            session: session, enhancer: enhancer,
            enhanceEnabled: true, previewEnabled: true, historyEnabled: true
        )
        await runToPreview(h)
        #expect(await waitUntil { h.preview.updates.count == 1 })

        h.preview.simulateConfirm("polished")
        #expect(await waitUntil { await h.history.readRecords().count == 1 })
        let record = await h.history.readRecords()[0]
        #expect(record.userCorrected == false)
    }

    @Test func previewCopyRecordsHistory() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true, historyEnabled: true)
        await runToPreview(h)

        h.preview.simulateCopy("raw")
        #expect(await waitUntil { await h.history.readRecords().count == 1 })
        let record = await h.history.readRecords()[0]
        #expect(record.previewEnabled == true)
        #expect(record.enhancedText == nil)
    }

    @Test func previewCancelRecordsNothing() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true, historyEnabled: true)
        await runToPreview(h)

        h.preview.simulateCancel()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await h.history.readRecords().isEmpty)
    }

    @Test func directPasteRecordsWithPreviewDisabled() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(session: session, enhancer: enhancer, enhanceEnabled: true, historyEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.spy.pasted == ["polished"] })

        #expect(await waitUntil { await h.history.readRecords().count == 1 })
        let record = await h.history.readRecords()[0]
        #expect(record.previewEnabled == false)
        #expect(record.asrText == "raw")
        #expect(record.enhancedText == "polished")
        #expect(record.finalText == "polished")
        #expect(record.userCorrected == false)
    }

    @Test func historyDisabledRecordsNothing() async {
        let session = FakeSession(finishResult: .success("raw"))
        let h = Harness(session: session, previewEnabled: true, historyEnabled: false)
        await runToPreview(h)

        h.preview.simulateConfirm("final")
        #expect(await waitUntil { h.spy.pasted == ["final"] })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await h.history.readRecords().isEmpty)
    }

    @Test func confirmedCorrectionInjectedIntoNextEnhancePrompt() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(
            session: session, enhancer: enhancer,
            enhanceEnabled: true, previewEnabled: true, historyEnabled: true
        )
        await runToPreview(h)
        #expect(await waitUntil { h.preview.updates.count == 1 })
        h.preview.simulateConfirm("fixed")
        #expect(await waitUntil { await h.history.readRecords().count == 1 })

        // The next session's prompt carries the confirmed correction.
        await runToPreview(h, expectedShown: 2)
        #expect(await waitUntil { h.prompts.prompts.count == 2 })
        #expect(h.prompts.prompts[0] == "prompt-proofread")
        #expect(h.prompts.prompts[1].hasPrefix("prompt-proofread"))
        #expect(h.prompts.prompts[1].contains(ConversationHistory.injectionHeader))
        #expect(h.prompts.prompts[1].contains("raw → fixed"))
    }

    @Test func historyDisabledSkipsInjection() async {
        let session = FakeSession(finishResult: .success("raw"))
        let enhancer = FakeEnhancer(result: .success("polished"))
        let h = Harness(
            session: session, enhancer: enhancer,
            enhanceEnabled: true, previewEnabled: true, historyEnabled: false
        )
        // Pre-existing history on disk must not leak into the prompt.
        await h.history.record(ConversationRecord(
            timestamp: ConversationRecord.makeTimestamp(),
            asrText: "raw", enhancedText: "x", finalText: "fixed",
            enhanceMode: "proofread", previewEnabled: true,
            asrModel: "apple", llmModel: "", userCorrected: true, audioDuration: 1
        ))

        await runToPreview(h)
        #expect(await waitUntil { h.prompts.prompts.count == 1 })
        #expect(h.prompts.prompts == ["prompt-proofread"])
    }

    // MARK: - Transcribing-phase preview (panel opens before ASR result)

    @Test func panelOpensWhileTranscribing() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        // The panel is up in transcribing state before any result exists.
        #expect(await waitUntil { h.preview.shown.count == 1 })
        #expect(h.preview.setups[0].isTranscribing == true)
        #expect(h.preview.setups[0].text == "")
        #expect(h.preview.asrResults.isEmpty)
        #expect(h.activity.phase == .transcribing)

        session.completeFinish(.success("hello"))
        #expect(await waitUntil { h.preview.asrResults.count == 1 })
        #expect(h.preview.asrResults[0].text == "hello")
        #expect(h.activity.phase == .idle)

        h.preview.simulateConfirm("hello")
        #expect(await waitUntil { h.spy.pasted == ["hello"] })
    }

    @Test func escDuringTranscribingCancelsSession() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 1 })

        h.preview.simulateCancel()
        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(h.preview.closeCount >= 1)
        #expect(session.cancelled)

        // A late result must not resurrect anything.
        session.completeFinish(.success("late"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.spy.pasted.isEmpty)
        #expect(h.preview.asrResults.isEmpty)
    }

    @Test func fnDownDuringTranscribingStartsNewSession() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 1 })

        // A new press discards the in-flight transcription and records again.
        h.controller.fnDown()
        #expect(h.preview.closeCount >= 1)
        #expect(session.cancelled)
        #expect(await waitUntil { await h.recorder.startCount == 2 })
    }

    @Test func confirmDuringTranscribingAbortsAndPastesTypedText() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 1 })

        h.preview.simulateConfirm("typed")
        #expect(await waitUntil { h.spy.pasted == ["typed"] })
        #expect(session.cancelled)
        #expect(h.activity.phase == .idle)
    }

    @Test func emptyTranscriptionShowsFailureInPanel() async {
        let session = FakeSession(finishResult: .success(""))
        let h = Harness(session: session, previewEnabled: true, historyEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.preview.asrFailures.count == 1 })
        #expect(h.preview.asrFailures[0] == "Empty transcription")
        #expect(h.preview.closeCount == 0)
        #expect(h.activity.phase == .idle)

        // The user can still type a final text and paste it; no history is
        // recorded for a session without ASR text.
        h.preview.simulateConfirm("typed by hand")
        #expect(await waitUntil { h.spy.pasted == ["typed by hand"] })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await h.history.readRecords().isEmpty)
    }

    @Test func transcriptionFailureShowsFailureInPanel() async {
        let session = FakeSession(finishResult: .failure(TranscriptionError.invalidResponse))
        let h = Harness(session: session, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.preview.asrFailures.count == 1 })
        #expect(h.preview.asrFailures[0] == "Transcription failed")
        #expect(h.preview.closeCount == 0)

        h.preview.simulateCancel()
        #expect(await waitUntil { h.activity.phase == .idle })
        #expect(h.spy.pasted.isEmpty)
    }

    @Test func transcribeWatchdogWithPanelShowsTimeout() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(
            session: session,
            previewEnabled: true,
            timing: VoiceInputTiming(minHold: .zero, transcribeTimeout: .milliseconds(30))
        )

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()

        #expect(await waitUntil { h.preview.asrFailures.count == 1 })
        #expect(h.preview.asrFailures[0] == "Transcription timed out")
        #expect(h.preview.closeCount == 0)
        #expect(session.cancelled)

        // The panel is still functional after the timeout.
        h.preview.simulateCancel()
        #expect(await waitUntil { h.activity.phase == .idle })
    }

    @Test func modeSwitchDuringTranscribingPreselectsMode() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(session: session, enhanceEnabled: true, previewEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { await h.recorder.startCount == 1 })
        h.controller.fnUp()
        #expect(await waitUntil { h.preview.shown.count == 1 })

        // Switching while STT runs only records the choice.
        h.preview.simulateModeSwitch("translate_en")
        #expect(h.settings.voiceEnhanceMode == "translate_en")
        #expect(h.prompts.prompts.isEmpty)

        // The upcoming enhancement uses the preselected mode.
        session.completeFinish(.success("raw"))
        #expect(await waitUntil { h.prompts.prompts.count == 1 })
        #expect(h.prompts.prompts[0] == "prompt-translate_en")
    }

    @Test func hudNotShownDuringTranscriptionWhenPanelOpen() async {
        let session = FakeSession(manualFinish: true)
        let h = Harness(session: session, previewEnabled: true, hudEnabled: true)

        h.controller.fnDown()
        #expect(await waitUntil { h.hud.showCount == 1 })
        h.controller.fnUp()

        // The panel replaces the HUD as soon as transcription starts.
        #expect(await waitUntil { h.preview.shown.count == 1 })
        #expect(h.hud.hideCount == 1)

        session.completeFinish(.success("hello"))
        #expect(await waitUntil { h.preview.asrResults.count == 1 })
        #expect(h.hud.showCount == 1)
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
        #expect(settings.voiceEnhanceMode == EnhanceMode.offModeID)
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
        settings1.voiceEnhanceMode = "translate_en"
        settings1.voicePreviewEnabled = true
        settings1.voiceHUDEnabled = false

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.voiceInputEnabled == true)
        #expect(settings2.voiceASRProviders == [groq])
        #expect(settings2.voiceASRSelection == .remote(provider: "groq", model: "whisper-large-v3"))
        #expect(settings2.voiceLLMProviders == [ollama])
        #expect(settings2.voiceLLMSelection == LLMSelection(provider: "ollama", model: "qwen3"))
        #expect(settings2.voiceLanguage == .chinese)
        #expect(settings2.voiceEnhanceMode == "translate_en")
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

    @Test func rejectsEmptyMode() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.voiceEnhanceMode = "  "
        #expect(settings.voiceEnhanceMode == EnhanceMode.offModeID)
    }
}
