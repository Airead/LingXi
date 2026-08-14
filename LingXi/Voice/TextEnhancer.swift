//
//  TextEnhancer.swift
//  LingXi
//

import Foundation

// MARK: - Protocol

/// Post-processes a transcription (proofread, punctuate, remove fillers).
protocol TextEnhancer: Sendable {
    func enhance(_ text: String) async throws -> String

    /// Streaming variant: `onDelta` receives each text chunk as it arrives
    /// (on an arbitrary thread); the returned value is the complete text.
    func enhanceStream(
        _ text: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

extension TextEnhancer {
    /// Non-streaming fallback: a single chunk-free request.
    func enhanceStream(
        _ text: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await enhance(text)
    }
}

// MARK: - Configuration

struct LLMEnhancerConfiguration: Sendable {
    var baseURL: String        // OpenAI-compatible, /chat/completions is appended
    var apiKey: String
    var model: String
    var systemPrompt: String
    var temperature: Double = 0.2
    var timeout: TimeInterval = 15

    static let defaultSystemPrompt = """
    你是语音转写文本的校对助手。修正同音字、错别字和标点，删除语气词（嗯、呃、啊、就是说等），\
    把口语表达整理得更通顺，但保持原意和语言不变。只输出修正后的文本，不要任何解释或额外内容。
    """
}

// MARK: - Request builder (pure, unit-testable)

nonisolated enum EnhanceRequestBuilder {
    static func makeRequest(
        configuration: LLMEnhancerConfiguration,
        text: String,
        stream: Bool = false
    ) throws -> URLRequest {
        let trimmed = configuration.baseURL.trimmingCharacters(in: .whitespaces)
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: base + "/chat/completions"), url.scheme != nil else {
            throw TranscriptionError.invalidConfiguration("Invalid enhancer base URL: \(configuration.baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = configuration.apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double
            let stream: Bool
        }
        request.httpBody = try JSONEncoder().encode(Body(
            model: configuration.model,
            messages: [
                Message(role: "system", content: configuration.systemPrompt),
                Message(role: "user", content: text),
            ],
            temperature: configuration.temperature,
            stream: stream
        ))
        return request
    }

    /// One server-sent event line of a streaming chat completion.
    enum StreamEvent: Equatable {
        case delta(String)
        case done
    }

    /// Parses a single SSE line; nil for empty lines, comments, role-only
    /// chunks and anything else without text content.
    static func parseStreamLine(_ line: String) -> StreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }

        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
            }
            let choices: [Choice]?
        }
        guard let decoded = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)),
              let content = decoded.choices?.first?.delta?.content,
              !content.isEmpty else {
            return nil
        }
        return .delta(content)
    }

    static func parseResponse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw TranscriptionError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - LLM enhancer

/// Sends the transcription to an OpenAI-compatible chat completions endpoint.
final class LLMTextEnhancer: TextEnhancer, @unchecked Sendable {
    private let configuration: LLMEnhancerConfiguration
    private let urlSession: URLSession

    init(configuration: LLMEnhancerConfiguration, urlSession: URLSession? = nil) {
        self.configuration = configuration
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.timeout
            self.urlSession = URLSession(configuration: config)
        }
    }

    @concurrent
    func enhance(_ text: String) async throws -> String {
        let request = try EnhanceRequestBuilder.makeRequest(configuration: configuration, text: text)
        let (data, response) = try await urlSession.data(for: request)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw TranscriptionError.apiError(statusCode: http.statusCode, body: body)
        }
        return try EnhanceRequestBuilder.parseResponse(data)
    }

    @concurrent
    func enhanceStream(
        _ text: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let request = try EnhanceRequestBuilder.makeRequest(
            configuration: configuration, text: text, stream: true
        )
        let (bytes, response) = try await urlSession.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 500 { break }
            }
            throw TranscriptionError.apiError(
                statusCode: http.statusCode,
                body: String(data: body, encoding: .utf8) ?? ""
            )
        }

        var full = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch EnhanceRequestBuilder.parseStreamLine(line) {
            case .delta(let delta):
                full += delta
                onDelta(delta)
            case .done:
                return full.trimmingCharacters(in: .whitespacesAndNewlines)
            case nil:
                continue
            }
        }
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
