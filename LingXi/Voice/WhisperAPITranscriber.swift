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
        guard let copy = Self.copy(buffer) else { return }
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

        let samples = try Self.convertToInt16Mono16k(recorded)
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

    // MARK: - Audio helpers

    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (srcBuffer, dstBuffer) in zip(src, dst) {
            guard let srcData = srcBuffer.mData, let dstData = dstBuffer.mData else { continue }
            memcpy(dstData, srcData, Int(min(srcBuffer.mDataByteSize, dstBuffer.mDataByteSize)))
        }
        return copy
    }

    private nonisolated static func convertToInt16Mono16k(_ buffers: [AVAudioPCMBuffer]) throws -> [Int16] {
        guard let sourceFormat = buffers.first?.format,
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw TranscriptionError.emptyAudio
        }

        var samples: [Int16] = []
        var inputIndex = 0
        var reachedEnd = false
        while !reachedEnd {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else {
                throw TranscriptionError.emptyAudio
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if inputIndex < buffers.count {
                    let next = buffers[inputIndex]
                    inputIndex += 1
                    outStatus.pointee = .haveData
                    return next
                }
                outStatus.pointee = .endOfStream
                return nil
            }
            switch status {
            case .haveData, .inputRanDry:
                if let channel = output.int16ChannelData, output.frameLength > 0 {
                    samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
                }
                if status == .inputRanDry { reachedEnd = true }
            case .endOfStream:
                reachedEnd = true
            case .error:
                throw conversionError ?? TranscriptionError.emptyAudio
            @unknown default:
                reachedEnd = true
            }
        }
        return samples
    }
}
