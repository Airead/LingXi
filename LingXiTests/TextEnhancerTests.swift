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
        struct StreamOptions: Decodable {
            let include_usage: Bool
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
        let stream_options: StreamOptions?
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
        // Usage arrives in the response body; no stream options needed.
        #expect(body.stream_options == nil)
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
        let outcome = try EnhanceRequestBuilder.parseResponse(data)
        #expect(outcome.text == "fixed text")
        #expect(outcome.usage == nil)
    }

    @Test func parsesResponseUsageWithOpenAICachedTokens() throws {
        let data = Data(#"""
        {"choices": [{"message": {"content": "x"}}],
         "usage": {"prompt_tokens": 567, "completion_tokens": 89, "total_tokens": 656,
                   "prompt_tokens_details": {"cached_tokens": 80}}}
        """#.utf8)
        let usage = try EnhanceRequestBuilder.parseResponse(data).usage
        #expect(usage == TokenUsage(
            promptTokens: 567, completionTokens: 89, totalTokens: 656, cacheReadTokens: 80
        ))
    }

    @Test func parsesResponseUsageWithDeepSeekCacheFallback() throws {
        let data = Data(#"""
        {"choices": [{"message": {"content": "x"}}],
         "usage": {"prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110,
                   "prompt_cache_hit_tokens": 64}}
        """#.utf8)
        #expect(try EnhanceRequestBuilder.parseResponse(data).usage?.cacheReadTokens == 64)
    }

    @Test func parsesResponseUsageWithoutCacheInfo() throws {
        let data = Data(#"""
        {"choices": [{"message": {"content": "x"}}],
         "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8}}
        """#.utf8)
        let usage = try EnhanceRequestBuilder.parseResponse(data).usage
        #expect(usage == TokenUsage(
            promptTokens: 5, completionTokens: 3, totalTokens: 8, cacheReadTokens: 0
        ))
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

    @Test func buildsStreamingRequest() throws {
        let request = try EnhanceRequestBuilder.makeRequest(configuration: config, text: "hello", stream: true)
        let body = try JSONDecoder().decode(DecodedBody.self, from: try #require(request.httpBody))
        #expect(body.stream == true)
        #expect(body.stream_options?.include_usage == true)
    }

    // MARK: - SSE line parsing

    @Test func parsesDeltaLine() {
        let line = #"data: {"choices": [{"delta": {"content": "Hel"}}]}"#
        #expect(EnhanceRequestBuilder.parseStreamLine(line) == [.delta("Hel")])
    }

    @Test func parsesDoneLine() {
        #expect(EnhanceRequestBuilder.parseStreamLine("data: [DONE]") == [.done])
        #expect(EnhanceRequestBuilder.parseStreamLine("data:[DONE]") == [.done])
    }

    @Test func parsesUsageOnlyChunk() {
        let line = #"""
        data: {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12, "prompt_tokens_details": {"cached_tokens": 4}}}
        """#
        #expect(EnhanceRequestBuilder.parseStreamLine(line) == [.usage(TokenUsage(
            promptTokens: 10, completionTokens: 2, totalTokens: 12, cacheReadTokens: 4
        ))])
    }

    @Test func chunkWithContentAndUsageYieldsBothEvents() {
        let line = #"""
        data: {"choices": [{"delta": {"content": "hi"}}], "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}
        """#
        #expect(EnhanceRequestBuilder.parseStreamLine(line) == [
            .delta("hi"),
            .usage(TokenUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2, cacheReadTokens: 0)),
        ])
    }

    @Test func ignoresNullAndZeroUsageChunks() {
        // Providers stream "usage": null until the final chunk.
        #expect(EnhanceRequestBuilder.parseStreamLine(
            #"data: {"choices": [], "usage": null}"#
        ) == [])
        #expect(EnhanceRequestBuilder.parseStreamLine(
            #"data: {"choices": [], "usage": {"total_tokens": 0}}"#
        ) == [])
    }

    @Test func ignoresNonDataAndEmptyLines() {
        #expect(EnhanceRequestBuilder.parseStreamLine("") == [])
        #expect(EnhanceRequestBuilder.parseStreamLine(": keep-alive comment") == [])
        #expect(EnhanceRequestBuilder.parseStreamLine("event: message") == [])
    }

    @Test func ignoresRoleOnlyAndEmptyContentChunks() {
        #expect(EnhanceRequestBuilder.parseStreamLine(
            #"data: {"choices": [{"delta": {"role": "assistant"}}]}"#
        ) == [])
        #expect(EnhanceRequestBuilder.parseStreamLine(
            #"data: {"choices": [{"delta": {"content": ""}}]}"#
        ) == [])
        #expect(EnhanceRequestBuilder.parseStreamLine(
            #"data: {"choices": [{"delta": {"content": null}}]}"#
        ) == [])
    }

    @Test func ignoresMalformedJSONLine() {
        #expect(EnhanceRequestBuilder.parseStreamLine("data: {broken json") == [])
    }
}

// MARK: - Token usage display

struct TokenUsageDisplayTests {

    @Test func formatsWithoutCache() {
        let usage = TokenUsage(promptTokens: 567, completionTokens: 89, totalTokens: 656, cacheReadTokens: 0)
        #expect(usage.displayText == "Tokens: 656 (↑567 ↓89)")
    }

    @Test func formatsCachedPlusUncached() {
        // WenZi format: cached first, then uncached.
        let usage = TokenUsage(promptTokens: 567, completionTokens: 89, totalTokens: 656, cacheReadTokens: 80)
        #expect(usage.displayText == "Tokens: 656 (↑80+487 ↓89)")
    }

    @Test func groupsThousandsWithCommas() {
        let usage = TokenUsage(
            promptTokens: 1200, completionTokens: 34, totalTokens: 1234, cacheReadTokens: 1000
        )
        #expect(usage.displayText == "Tokens: 1,234 (↑1,000+200 ↓34)")
    }

    @Test func hiddenWhenNothingReported() {
        let usage = TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0, cacheReadTokens: 0)
        #expect(usage.displayText == nil)
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
            (200, Data(#"""
            {"choices": [{"message": {"content": " better text "}}],
             "usage": {"prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15}}
            """#.utf8))
        }
        let outcome = try await makeEnhancer().enhance("raw text")
        #expect(outcome.text == "better text")
        #expect(outcome.usage == TokenUsage(
            promptTokens: 12, completionTokens: 3, totalTokens: 15, cacheReadTokens: 0
        ))
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

    // MARK: - Streaming

    /// Collects deltas delivered on arbitrary threads.
    private final class DeltaCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _deltas: [String] = []
        var deltas: [String] { lock.withLock { _deltas } }
        func append(_ delta: String) { lock.withLock { _deltas.append(delta) } }
    }

    @Test func streamsDeltasAndReturnsFullText() async throws {
        let sse = """
        data: {"choices": [{"delta": {"role": "assistant"}}]}

        data: {"choices": [{"delta": {"content": "bet"}}]}

        data: {"choices": [{"delta": {"content": "ter"}}]}

        data: {"choices": [{"delta": {"content": " text"}}]}

        data: {"choices": [], "usage": {"prompt_tokens": 20, "completion_tokens": 5, "total_tokens": 25, "prompt_tokens_details": {"cached_tokens": 8}}}

        data: [DONE]

        """
        EnhanceMockURLProtocol.handler = { request in
            // The streaming request body must carry stream:true.
            let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                return data
            } ?? Data()
            #expect(String(data: body, encoding: .utf8)?.contains(#""stream":true"#) == true)
            return (200, Data(sse.utf8))
        }
        let collector = DeltaCollector()
        let outcome = try await makeEnhancer().enhanceStream("raw text") { collector.append($0) }
        #expect(outcome.text == "better text")
        #expect(collector.deltas == ["bet", "ter", " text"])
        #expect(outcome.usage == TokenUsage(
            promptTokens: 20, completionTokens: 5, totalTokens: 25, cacheReadTokens: 8
        ))
    }

    @Test func streamWithoutDoneStillReturnsAccumulatedText() async throws {
        let sse = """
        data: {"choices": [{"delta": {"content": "hi"}}]}

        """
        EnhanceMockURLProtocol.handler = { _ in (200, Data(sse.utf8)) }
        let outcome = try await makeEnhancer().enhanceStream("raw") { _ in }
        #expect(outcome.text == "hi")
        #expect(outcome.usage == nil)
    }

    @Test func streamThrowsAPIErrorOnNon2xx() async {
        EnhanceMockURLProtocol.handler = { _ in (500, Data(#"{"error": "boom"}"#.utf8)) }
        await #expect(throws: TranscriptionError.apiError(statusCode: 500, body: #"{"error": "boom"}"#)) {
            _ = try await makeEnhancer().enhanceStream("raw") { _ in }
        }
    }
}
