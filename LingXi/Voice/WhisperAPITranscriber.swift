//
//  WhisperAPITranscriber.swift
//  LingXi
//

import AVFoundation
import Foundation

// MARK: - Configuration

struct WhisperAPIConfiguration: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    var temperature: Double = 0.0
}

// MARK: - Request builder (pure, unit-testable)

nonisolated enum WhisperRequestBuilder {
    static func makeRequest(
        configuration: WhisperAPIConfiguration,
        languageCode: String?,
        wavData: Data,
        boundary: String = UUID().uuidString
    ) throws -> URLRequest {
        let trimmed = configuration.baseURL.trimmingCharacters(in: .whitespaces)
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: base + "/audio/transcriptions"), url.scheme != nil else {
            throw TranscriptionError.invalidConfiguration("Invalid API base URL: \(configuration.baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        appendField("model", configuration.model)
        appendField("temperature", String(configuration.temperature))
        if let languageCode, !languageCode.isEmpty {
            appendField("language", languageCode)
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }
}

// MARK: - Transcriber

final class WhisperAPITranscriber: SpeechTranscriber, @unchecked Sendable {
    private let configuration: WhisperAPIConfiguration
    private let urlSession: URLSession

    init(configuration: WhisperAPIConfiguration, urlSession: URLSession? = nil) {
        self.configuration = configuration
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            self.urlSession = URLSession(configuration: config)
        }
    }

    func makeSession(language: VoiceLanguage) async throws -> any SpeechTranscriptionSession {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TranscriptionError.invalidConfiguration("Whisper API key is not set")
        }
        return WhisperAPISession(
            configuration: configuration,
            languageCode: language.whisperCode,
            urlSession: urlSession
        )
    }
}

// MARK: - Session

/// Accumulates raw audio buffers during recording; on finish() converts to
/// 16 kHz mono Int16 WAV and uploads to the API. Buffer accumulation is
/// lock-protected because append() runs on the realtime audio thread while
/// finish()/cancel() run elsewhere. Format conversion and networking happen
/// off the main actor via @concurrent.
final class WhisperAPISession: SpeechTranscriptionSession, @unchecked Sendable {
    private let configuration: WhisperAPIConfiguration
    private let languageCode: String?
    private let urlSession: URLSession

    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var cancelled = false
    private var finished = false
    private var workTask: Task<String, Error>?

    init(configuration: WhisperAPIConfiguration, languageCode: String?, urlSession: URLSession) {
        self.configuration = configuration
        self.languageCode = languageCode
        self.urlSession = urlSession
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        // Copy first: the tap may reuse the buffer after the callback returns.
        guard let copy = AudioBufferConversion.copy(buffer) else { return }
        lock.withLock {
            guard !cancelled, !finished else { return }
            buffers.append(copy)
        }
    }

    nonisolated func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) {
        // Batch backend: no streaming partials.
    }

    func finish() async throws -> String {
        let work: Task<String, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            guard !cancelled else { return nil }
            let task = Task { try await self.performFinish() }
            workTask = task
            return task
        }
        guard let work else { throw CancellationError() }
        return try await work.value
    }

    nonisolated func cancel() {
        let task: Task<String, Error>? = lock.withLock {
            cancelled = true
            buffers.removeAll()
            return workTask
        }
        task?.cancel()
    }

    @concurrent
    private func performFinish() async throws -> String {
        let recorded = lock.withLock { buffers }
        guard !recorded.isEmpty else { throw TranscriptionError.emptyAudio }

        let samples = try AudioBufferConversion.convertToInt16Mono16k(recorded)
        guard !samples.isEmpty else { throw TranscriptionError.emptyAudio }
        try Task.checkCancellation()

        let wavData = WAVEncoder.encode(samples: samples, sampleRate: 16000)
        let request = try WhisperRequestBuilder.makeRequest(
            configuration: configuration,
            languageCode: languageCode,
            wavData: wavData
        )

        let (data, response) = try await urlSession.data(for: request)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw TranscriptionError.apiError(statusCode: http.statusCode, body: body)
        }

        struct WhisperResponse: Decodable { let text: String }
        guard let decoded = try? JSONDecoder().decode(WhisperResponse.self, from: data) else {
            throw TranscriptionError.invalidResponse
        }
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
