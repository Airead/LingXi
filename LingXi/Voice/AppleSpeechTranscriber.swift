//
//  AppleSpeechTranscriber.swift
//  LingXi
//

import AVFoundation
import Foundation
import Speech

final class AppleSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
    func makeSession(language: VoiceLanguage) async throws -> any SpeechTranscriptionSession {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw TranscriptionError.notAuthorized }
        default:
            throw TranscriptionError.notAuthorized
        }
        let recognizer: SFSpeechRecognizer? = if let identifier = language.localeIdentifier {
            SFSpeechRecognizer(locale: Locale(identifier: identifier))
        } else {
            SFSpeechRecognizer()
        }
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        return AppleSpeechSession(recognizer: recognizer)
    }

    /// Re-transcription: decodes the retained WAV and replays it through a
    /// fresh streaming session (faster-than-realtime feeding is fine).
    func transcribe(wavData: Data, language: VoiceLanguage) async throws -> String {
        guard let samples = WAVDecoder.decodeSamples(wavData), !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
              ) else {
            throw TranscriptionError.emptyAudio
        }
        let session = try await makeSession(language: language)

        var index = 0
        while index < samples.count {
            let count = min(4096, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(count)
            ), let channel = buffer.int16ChannelData else {
                session.cancel()
                throw TranscriptionError.emptyAudio
            }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                channel[0].update(from: source.baseAddress! + index, count: count)
            }
            session.append(buffer)
            index += count
        }

        return try await withTaskCancellationHandler {
            try await session.finish()
        } onCancel: {
            session.cancel()
        }
    }
}

/// Streaming recognition session. Recognition callbacks may arrive on any
/// queue, so all mutable state is lock-protected and the pending continuation
/// is resumed exactly once (taken out of the lock before resuming).
nonisolated final class AppleSpeechSession: SpeechTranscriptionSession, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest

    private let lock = NSLock()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestText = ""
    private var finalResult: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private var cancelled = false
    private var finishCalled = false
    private var partialHandler: (@Sendable (String) -> Void)?

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Only force on-device when supported, so languages without a local
        // model can still fall back to server-based recognition.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognition(result: result, error: error)
        }
    }

    deinit {
        recognitionTask?.cancel()
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        let accepting = lock.withLock { !cancelled && !finishCalled }
        if accepting {
            request.append(buffer)
        }
    }

    nonisolated func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { partialHandler = handler }
    }

    func finish() async throws -> String {
        lock.withLock { finishCalled = true }
        request.endAudio()
        return try await withCheckedThrowingContinuation { newContinuation in
            let immediate: Result<String, Error>? = lock.withLock {
                if let finalResult { return finalResult }
                if cancelled { return .failure(CancellationError()) }
                continuation = newContinuation
                return nil
            }
            if let immediate {
                newContinuation.resume(with: immediate)
            }
        }
    }

    nonisolated func cancel() {
        let (pending, task): (CheckedContinuation<String, Error>?, SFSpeechRecognitionTask?) = lock.withLock {
            cancelled = true
            if finalResult == nil { finalResult = .failure(CancellationError()) }
            let pending = continuation
            continuation = nil
            return (pending, recognitionTask)
        }
        task?.cancel()
        request.endAudio()
        pending?.resume(throwing: CancellationError())
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        // Take the handler inside the lock, invoke it outside (same
        // discipline as the continuation) so user code never runs locked.
        var partialNotification: (@Sendable (String) -> Void, String)?
        let resumption: (CheckedContinuation<String, Error>, Result<String, Error>)? = lock.withLock {
            if let result {
                latestText = result.bestTranscription.formattedString
                if !cancelled, let handler = partialHandler {
                    partialNotification = (handler, latestText)
                }
                guard result.isFinal else { return nil }
                if finalResult == nil { finalResult = .success(latestText) }
            } else if let error {
                if finalResult == nil {
                    // endAudio often surfaces an error after partials stop;
                    // fall back to the latest partial text if we have any.
                    finalResult = latestText.isEmpty ? .failure(error) : .success(latestText)
                }
            } else {
                return nil
            }
            guard let pending = continuation, let finalResult else { return nil }
            continuation = nil
            return (pending, finalResult)
        }
        if let (handler, text) = partialNotification {
            handler(text)
        }
        if let (pending, result) = resumption {
            pending.resume(with: result)
        }
    }
}
