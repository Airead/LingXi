import Foundation
import Testing
@testable import LingXi

// MARK: - Request builder

struct EnhanceRequestBuilderTests {

    private let config = LLMEnhancerConfiguration(
        baseURL: "https://api.example.com/v1",
        apiKey: "sk-test",
        model: "gpt-test",
        systemPrompt: "fix it"
    )

    private struct DecodedBody: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
    }

    @Test func buildsRequest() throws {
        let request = try EnhanceRequestBuilder.makeRequest(configuration: config, text: "hello")

        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONDecoder().decode(DecodedBody.self, from: try #require(request.httpBody))
        #expect(body.model == "gpt-test")
        #expect(body.temperature == 0.2)
        #expect(body.stream == false)
        #expect(body.messages.count == 2)
        #expect(body.messages[0].role == "system")
        #expect(body.messages[0].content == "fix it")
        #expect(body.messages[1].role == "user")
        #expect(body.messages[1].content == "hello")
    }

    @Test func omitsAuthorizationWhenKeyEmpty() throws {
        var local = config
        local.apiKey = "  "
        let request = try EnhanceRequestBuilder.makeRequest(configuration: local, text: "hi")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func trimsTrailingSlashInBaseURL() throws {
        var slashed = config
        slashed.baseURL = "https://api.example.com/v1/"
        let request = try EnhanceRequestBuilder.makeRequest(configuration: slashed, text: "hi")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test func rejectsInvalidBaseURL() {
        var bad = config
        bad.baseURL = "not a url"
        #expect(throws: TranscriptionError.self) {
            _ = try EnhanceRequestBuilder.makeRequest(configuration: bad, text: "hi")
        }
    }

    @Test func parsesResponse() throws {
        let data = Data(#"{"choices": [{"message": {"role": "assistant", "content": " fixed text \n"}}]}"#.utf8)
        #expect(try EnhanceRequestBuilder.parseResponse(data) == "fixed text")
    }

    @Test func parseRejectsBadJSON() {
        #expect(throws: TranscriptionError.invalidResponse) {
            _ = try EnhanceRequestBuilder.parseResponse(Data("not json".utf8))
        }
    }

    @Test func parseRejectsEmptyChoices() {
        #expect(throws: TranscriptionError.invalidResponse) {
            _ = try EnhanceRequestBuilder.parseResponse(Data(#"{"choices": []}"#.utf8))
        }
    }
}

// MARK: - Enhancer with a mocked URLProtocol

/// Separate from MockURLProtocol in WhisperAPITranscriberTests so the two
/// suites can't race on a shared static handler.
final class EnhanceMockURLProtocol: URLProtocol {
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
struct LLMTextEnhancerTests {

    private func makeEnhancer() -> LLMTextEnhancer {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EnhanceMockURLProtocol.self]
        return LLMTextEnhancer(
            configuration: LLMEnhancerConfiguration(
                baseURL: "https://api.example.com/v1",
                apiKey: "sk-test",
                model: "gpt-test",
                systemPrompt: "fix it"
            ),
            urlSession: URLSession(configuration: config)
        )
    }

    @Test func enhancesText() async throws {
        EnhanceMockURLProtocol.handler = { _ in
            (200, Data(#"{"choices": [{"message": {"content": " better text "}}]}"#.utf8))
        }
        let text = try await makeEnhancer().enhance("raw text")
        #expect(text == "better text")
    }

    @Test func throwsAPIErrorOnNon2xx() async {
        EnhanceMockURLProtocol.handler = { _ in
            (500, Data(#"{"error": "boom"}"#.utf8))
        }
        await #expect(throws: TranscriptionError.apiError(statusCode: 500, body: #"{"error": "boom"}"#)) {
            _ = try await makeEnhancer().enhance("raw text")
        }
    }

    @Test func throwsInvalidResponseOnBadJSON() async {
        EnhanceMockURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        await #expect(throws: TranscriptionError.invalidResponse) {
            _ = try await makeEnhancer().enhance("raw text")
        }
    }
}
