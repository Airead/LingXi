import AVFoundation
import Foundation
import Testing
@testable import LingXi

struct WhisperRequestBuilderTests {

    private let config = WhisperAPIConfiguration(
        baseURL: "https://api.example.com/v1",
        apiKey: "sk-test",
        model: "whisper-1"
    )

    @Test func buildsRequest() throws {
        let wav = Data([0x01, 0x02, 0x03])
        let request = try WhisperRequestBuilder.makeRequest(
            configuration: config,
            languageCode: "zh",
            wavData: wav,
            boundary: "BOUNDARY"
        )

        #expect(request.url?.absoluteString == "https://api.example.com/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")

        let body = try #require(request.httpBody)
        let bodyString = String(decoding: body, as: UTF8.self)
        #expect(bodyString.contains("--BOUNDARY\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"))
        #expect(bodyString.contains("name=\"temperature\"\r\n\r\n0.0\r\n"))
        #expect(bodyString.contains("name=\"language\"\r\n\r\nzh\r\n"))
        #expect(bodyString.contains("name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        #expect(bodyString.hasSuffix("\r\n--BOUNDARY--\r\n"))
        #expect(body.contains(wav))
    }

    @Test func omitsLanguageWhenNil() throws {
        let request = try WhisperRequestBuilder.makeRequest(
            configuration: config, languageCode: nil, wavData: Data(), boundary: "B"
        )
        let bodyString = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(!bodyString.contains("name=\"language\""))
    }

    @Test func trimsTrailingSlashInBaseURL() throws {
        var slashed = config
        slashed.baseURL = "https://api.example.com/v1/"
        let request = try WhisperRequestBuilder.makeRequest(
            configuration: slashed, languageCode: nil, wavData: Data(), boundary: "B"
        )
        #expect(request.url?.absoluteString == "https://api.example.com/v1/audio/transcriptions")
    }

    @Test func rejectsInvalidBaseURL() {
        var bad = config
        bad.baseURL = "not a url"
        #expect(throws: TranscriptionError.self) {
            _ = try WhisperRequestBuilder.makeRequest(
                configuration: bad, languageCode: nil, wavData: Data(), boundary: "B"
            )
        }
    }
}

// MARK: - Session tests with a mocked URLProtocol

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct WhisperAPISessionTests {

    private func makeSession() async throws -> any SpeechTranscriptionSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let transcriber = WhisperAPITranscriber(
            configuration: WhisperAPIConfiguration(
                baseURL: "https://api.example.com/v1", apiKey: "sk-test", model: "whisper-1"
            ),
            urlSession: URLSession(configuration: config)
        )
        return try await transcriber.makeSession(language: .auto)
    }

    private func makeBuffer(frames: AVAudioFrameCount = 1600) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = sin(Float(i) * 0.1) * 0.5
        }
        return buffer
    }

    @Test func transcribesAudio() async throws {
        MockURLProtocol.handler = { _ in
            (200, Data(#"{"text": "  hello world "}"#.utf8))
        }
        let session = try await makeSession()
        session.append(makeBuffer())
        let text = try await session.finish()
        #expect(text == "hello world")
    }

    @Test func throwsAPIErrorOnNon2xx() async throws {
        MockURLProtocol.handler = { _ in
            (401, Data(#"{"error": "bad key"}"#.utf8))
        }
        let session = try await makeSession()
        session.append(makeBuffer())
        await #expect(throws: TranscriptionError.apiError(statusCode: 401, body: #"{"error": "bad key"}"#)) {
            _ = try await session.finish()
        }
    }

    @Test func throwsInvalidResponseOnBadJSON() async throws {
        MockURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        let session = try await makeSession()
        session.append(makeBuffer())
        await #expect(throws: TranscriptionError.invalidResponse) {
            _ = try await session.finish()
        }
    }

    @Test func throwsEmptyAudioWithoutBuffers() async throws {
        MockURLProtocol.handler = { _ in (200, Data()) }
        let session = try await makeSession()
        await #expect(throws: TranscriptionError.emptyAudio) {
            _ = try await session.finish()
        }
    }

    @Test func cancelBeforeFinishThrowsCancellation() async throws {
        MockURLProtocol.handler = { _ in (200, Data(#"{"text": "x"}"#.utf8)) }
        let session = try await makeSession()
        session.append(makeBuffer())
        session.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await session.finish()
        }
    }

    @Test func rejectsEmptyAPIKey() async {
        let transcriber = WhisperAPITranscriber(
            configuration: WhisperAPIConfiguration(baseURL: "https://a.example", apiKey: " ", model: "m")
        )
        await #expect(throws: TranscriptionError.self) {
            _ = try await transcriber.makeSession(language: .auto)
        }
    }
}
