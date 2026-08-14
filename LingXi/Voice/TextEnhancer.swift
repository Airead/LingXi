//
//  TextEnhancer.swift
//  LingXi
//

import Foundation

// MARK: - Token usage

/// LLM token usage of one enhancement request, shown in the preview panel.
nonisolated struct TokenUsage: Sendable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int
    /// Cached input tokens; 0 when the provider does not report cache info.
    var cacheReadTokens: Int

    /// WenZi-style suffix, e.g. "Tokens: 1,234 (↑80+487 ↓89)" — on a cache
    /// hit the up part is "cached+uncached". Nil when nothing was reported.
    var displayText: String? {
        guard totalTokens > 0 else { return nil }
        let up = cacheReadTokens > 0
            ? "↑\(Self.formatted(cacheReadTokens))+\(Self.formatted(promptTokens - cacheReadTokens))"
            : "↑\(Self.formatted(promptTokens))"
        return "Tokens: \(Self.formatted(totalTokens)) (\(up) ↓\(Self.formatted(completionTokens)))"
    }

    private static func formatted(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}

/// Result of one enhancement request.
nonisolated struct EnhanceOutcome: Sendable, Equatable {
    var text: String
    var usage: TokenUsage?
}

// MARK: - Protocol

/// Post-processes a transcription (proofread, punctuate, remove fillers).
protocol TextEnhancer: Sendable {
    func enhance(_ text: String) async throws -> EnhanceOutcome

    /// Streaming variant: `onDelta` receives each text chunk as it arrives
    /// (on an arbitrary thread); the returned value is the complete result.
    func enhanceStream(
        _ text: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> EnhanceOutcome
}

extension TextEnhancer {
    /// Non-streaming fallback: a single chunk-free request.
    func enhanceStream(
        _ text: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> EnhanceOutcome {
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

    /// WenZi's proofread mode prompt, copied verbatim.
    static let defaultSystemPrompt = """
    你是一个语音识别文本纠错助手，支持中文和英文。你只做纠错，不做翻译、不做改写、不做润色。

    用户输入来自语音识别（Whisper，已启用标点恢复），可能包含谐音字、同音字替换、吞字漏字等识别错误。\
    请根据输入语言自动适配纠错规则。

    规则（按优先级排列）：
    1. 输出语言与当前这条输入的语言保持一致，不因对话历史语言不同而翻译
    2. 不确定的词保留原文，不猜测、不脑补未说出的内容；宁可少改，不要错改
    3. 命令、路径、文件名、URL、代码标识符、环境变量保留字面形式，不做自然语言化处理
    4. 保持原文语义和口语风格，只修正明显的 ASR 识别错误（错字、同音字、分词错误）
    5. 专有名词使用标准写法和大小写（如 CUDA、GitHub、Ethereum），不保留 ASR 的错误拼写
    6. 重点关注计算机、AI、区块链、金融领域的专业术语，但仅在上下文充分支持且发音或拼写接近时才纠正
    7. 中英文混排时加一个半角空格，纯中文或纯英文内部按各自规范
    8. 中文语境使用全角标点，英文语境使用半角标点；文本末尾不加句号等陈述性标点，但保留问号、感叹号等语气标点
    9. 在明显缺失分隔的长句中补充标点，已有标点的部分仅修正明显错误
    10. 去除无语义作用的口语填充词（中文如“呢”“啊”“那个”，英文如“um”“uh”“like”“you know”），\
    但保留有确认、回应、连接作用的用法（如“好，那我们...”中的“好”）
    11. 数字默认使用阿拉伯数字，保留约定俗成的表达（中文如“一带一路”，英文如“Area 51”）
    12. 对话历史和词库仅作为消歧参考，当证据不足时以当前句字面内容为准，不得用历史内容覆盖当前句的数字、编号、实体名
    13. 直接输出修正后的文本，不要添加任何解释或说明
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
        struct StreamOptions: Encodable {
            let include_usage: Bool
        }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double
            let stream: Bool
            /// Asks for a final usage chunk; omitted for non-streaming
            /// requests (usage comes in the response body there).
            let stream_options: StreamOptions?
        }
        request.httpBody = try JSONEncoder().encode(Body(
            model: configuration.model,
            messages: [
                Message(role: "system", content: configuration.systemPrompt),
                Message(role: "user", content: text),
            ],
            temperature: configuration.temperature,
            stream: stream,
            stream_options: stream ? StreamOptions(include_usage: true) : nil
        ))
        return request
    }

    /// OpenAI-compatible usage payload; the cache-read count tries
    /// `prompt_tokens_details.cached_tokens` (OpenAI standard) first, then
    /// `prompt_cache_hit_tokens` (DeepSeek).
    private struct UsagePayload: Decodable {
        struct Details: Decodable { let cached_tokens: Int? }
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
        let prompt_tokens_details: Details?
        let prompt_cache_hit_tokens: Int?

        var tokenUsage: TokenUsage {
            let cached: Int = if let c = prompt_tokens_details?.cached_tokens, c > 0 {
                c
            } else {
                prompt_cache_hit_tokens ?? 0
            }
            return TokenUsage(
                promptTokens: prompt_tokens ?? 0,
                completionTokens: completion_tokens ?? 0,
                totalTokens: total_tokens ?? 0,
                cacheReadTokens: cached
            )
        }
    }

    /// One server-sent event line of a streaming chat completion.
    enum StreamEvent: Equatable {
        case delta(String)
        /// The dedicated usage chunk requested via `include_usage`.
        case usage(TokenUsage)
        case done
    }

    /// Parses a single SSE line into its events; empty for comments,
    /// role-only chunks and anything else without content or usage. A chunk
    /// carrying both text and usage yields both events.
    static func parseStreamLine(_ line: String) -> [StreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return [] }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [.done] }

        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
            }
            let choices: [Choice]?
            let usage: UsagePayload?
        }
        guard let decoded = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else {
            return []
        }
        var events: [StreamEvent] = []
        if let content = decoded.choices?.first?.delta?.content, !content.isEmpty {
            events.append(.delta(content))
        }
        if let usage = decoded.usage?.tokenUsage, usage.totalTokens > 0 {
            events.append(.usage(usage))
        }
        return events
    }

    static func parseResponse(_ data: Data) throws -> EnhanceOutcome {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
            let usage: UsagePayload?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw TranscriptionError.invalidResponse
        }
        return EnhanceOutcome(
            text: content.trimmingCharacters(in: .whitespacesAndNewlines),
            usage: decoded.usage?.tokenUsage
        )
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
    func enhance(_ text: String) async throws -> EnhanceOutcome {
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
    ) async throws -> EnhanceOutcome {
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
        var usage: TokenUsage?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in EnhanceRequestBuilder.parseStreamLine(line) {
                switch event {
                case .delta(let delta):
                    full += delta
                    onDelta(delta)
                case .usage(let reported):
                    usage = reported
                case .done:
                    return EnhanceOutcome(
                        text: full.trimmingCharacters(in: .whitespacesAndNewlines),
                        usage: usage
                    )
                }
            }
        }
        return EnhanceOutcome(
            text: full.trimmingCharacters(in: .whitespacesAndNewlines),
            usage: usage
        )
    }
}
