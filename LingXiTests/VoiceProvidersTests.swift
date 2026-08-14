import Foundation
import Testing
@testable import LingXi

// MARK: - Codable round trips

struct VoiceProviderCodableTests {

    @Test func providerRoundTrip() throws {
        let provider = VoiceProvider(
            name: "groq", baseURL: "https://api.groq.com/openai/v1",
            apiKey: "gsk_test", models: ["whisper-large-v3", "whisper-large-v3-turbo"]
        )
        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(VoiceProvider.self, from: data)
        #expect(decoded == provider)
    }

    @Test func asrSelectionRoundTrip() throws {
        for selection in [ASRSelection.apple, .remote(provider: "groq", model: "whisper-large-v3")] {
            let data = try JSONEncoder().encode(selection)
            let decoded = try JSONDecoder().decode(ASRSelection.self, from: data)
            #expect(decoded == selection)
        }
    }

    @Test func llmSelectionRoundTrip() throws {
        let selection = LLMSelection(provider: "ollama", model: "qwen3")
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(LLMSelection.self, from: data)
        #expect(decoded == selection)
    }

    @Test func providerDecodingIgnoresUnknownFields() throws {
        let json = #"{"name":"x","baseURL":"https://x.test/v1","apiKey":"","models":["m"],"future":"field"}"#
        let decoded = try JSONDecoder().decode(VoiceProvider.self, from: Data(json.utf8))
        #expect(decoded.name == "x")
        #expect(decoded.models == ["m"])
    }
}

// MARK: - Resolver

struct VoiceProviderResolverTests {

    private let groq = VoiceProvider(
        name: "groq", baseURL: "https://api.groq.com/openai/v1",
        apiKey: "gsk", models: ["large-v3", "turbo"]
    )
    private let ollama = VoiceProvider(
        name: "ollama", baseURL: "http://localhost:11434/v1",
        apiKey: "", models: ["qwen3"]
    )

    @Test func asrAppleResolvesToApple() {
        #expect(VoiceProviderResolver.resolveASR(selection: .apple, providers: [groq]) == .apple)
    }

    @Test func asrExactMatchResolves() {
        let resolution = VoiceProviderResolver.resolveASR(
            selection: .remote(provider: "groq", model: "turbo"), providers: [groq, ollama]
        )
        #expect(resolution == .remote(provider: groq, model: "turbo"))
    }

    @Test func asrMissingProviderFallsBackToApple() {
        let resolution = VoiceProviderResolver.resolveASR(
            selection: .remote(provider: "gone", model: "turbo"), providers: [groq]
        )
        #expect(resolution == .apple)
    }

    @Test func asrMissingModelFallsBackToFirstModel() {
        let resolution = VoiceProviderResolver.resolveASR(
            selection: .remote(provider: "groq", model: "removed"), providers: [groq]
        )
        #expect(resolution == .remote(provider: groq, model: "large-v3"))
    }

    @Test func asrProviderWithoutModelsFallsBackToApple() {
        let empty = VoiceProvider(name: "empty", baseURL: "https://x.test/v1", apiKey: "", models: [])
        let resolution = VoiceProviderResolver.resolveASR(
            selection: .remote(provider: "empty", model: "m"), providers: [empty]
        )
        #expect(resolution == .apple)
    }

    @Test func llmExactMatchResolves() {
        let resolved = VoiceProviderResolver.resolveLLM(
            selection: LLMSelection(provider: "ollama", model: "qwen3"), providers: [groq, ollama]
        )
        #expect(resolved?.provider == ollama)
        #expect(resolved?.model == "qwen3")
    }

    @Test func llmMissingModelFallsBackToFirstModelOfProvider() {
        let resolved = VoiceProviderResolver.resolveLLM(
            selection: LLMSelection(provider: "groq", model: "removed"), providers: [groq, ollama]
        )
        #expect(resolved?.provider == groq)
        #expect(resolved?.model == "large-v3")
    }

    @Test func llmMissingProviderFallsBackToFirstAvailable() {
        let resolved = VoiceProviderResolver.resolveLLM(
            selection: LLMSelection(provider: "gone", model: "x"), providers: [groq, ollama]
        )
        #expect(resolved?.provider == groq)
        #expect(resolved?.model == "large-v3")
    }

    @Test func llmSkipsProvidersWithoutModels() {
        let empty = VoiceProvider(name: "empty", baseURL: "https://x.test/v1", apiKey: "", models: [])
        let resolved = VoiceProviderResolver.resolveLLM(
            selection: LLMSelection(provider: "gone", model: "x"), providers: [empty, ollama]
        )
        #expect(resolved?.provider == ollama)
    }

    @Test func llmNoProvidersResolvesToNil() {
        let resolved = VoiceProviderResolver.resolveLLM(
            selection: LLMSelection(provider: "a", model: "b"), providers: []
        )
        #expect(resolved == nil)
    }
}

// MARK: - Settings migration

@MainActor
struct VoiceProviderMigrationTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "io.github.airead.lingxi.test.\(UUID().uuidString)")!
    }

    @Test func migratesLegacyWhisperConfigToRemoteSelection() {
        let defaults = makeDefaults()
        defaults.set("whisperAPI", forKey: "io.github.airead.lingxi.voiceBackend")
        defaults.set("https://api.groq.com/openai/v1", forKey: "io.github.airead.lingxi.voiceAPIBaseURL")
        defaults.set("gsk_test", forKey: "io.github.airead.lingxi.voiceAPIKey")
        defaults.set("whisper-large-v3", forKey: "io.github.airead.lingxi.voiceAPIModel")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceASRProviders == [VoiceProvider(
            name: "default", baseURL: "https://api.groq.com/openai/v1",
            apiKey: "gsk_test", models: ["whisper-large-v3"]
        )])
        #expect(settings.voiceASRSelection == .remote(provider: "default", model: "whisper-large-v3"))
    }

    @Test func migratesLegacyAppleBackendKeepingProviderAsTemplate() {
        let defaults = makeDefaults()
        defaults.set("apple", forKey: "io.github.airead.lingxi.voiceBackend")
        defaults.set("sk-test", forKey: "io.github.airead.lingxi.voiceAPIKey")

        let settings = AppSettings(defaults: defaults)
        // The configured endpoint is carried over, but Apple stays selected.
        #expect(settings.voiceASRProviders.count == 1)
        #expect(settings.voiceASRProviders[0].apiKey == "sk-test")
        #expect(settings.voiceASRProviders[0].baseURL == "https://api.openai.com/v1")
        #expect(settings.voiceASRSelection == .apple)
    }

    @Test func migratesLegacyEnhanceConfigToLLMProvider() {
        let defaults = makeDefaults()
        defaults.set("https://api.example.com/v1", forKey: "io.github.airead.lingxi.voiceEnhanceBaseURL")
        defaults.set("sk-enhance", forKey: "io.github.airead.lingxi.voiceEnhanceAPIKey")
        defaults.set("gpt-test", forKey: "io.github.airead.lingxi.voiceEnhanceModel")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceLLMProviders == [VoiceProvider(
            name: "default", baseURL: "https://api.example.com/v1",
            apiKey: "sk-enhance", models: ["gpt-test"]
        )])
        #expect(settings.voiceLLMSelection == LLMSelection(provider: "default", model: "gpt-test"))
    }

    @Test func migratesEnabledEnhanceWithDefaultEndpointValues() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "io.github.airead.lingxi.voiceEnhanceEnabled")

        let settings = AppSettings(defaults: defaults)
        // The user relied on the built-in Ollama defaults; carry them over.
        #expect(settings.voiceLLMProviders == [VoiceProvider(
            name: "default", baseURL: "http://localhost:11434/v1",
            apiKey: "", models: ["qwen3"]
        )])
        #expect(settings.voiceLLMSelection == LLMSelection(provider: "default", model: "qwen3"))
    }

    @Test func freshInstallGetsEmptyProvidersAndAppleSelection() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.voiceASRProviders.isEmpty)
        #expect(settings.voiceASRSelection == .apple)
        #expect(settings.voiceLLMProviders.isEmpty)
    }

    @Test func migrationDoesNotRepeatOnceNewKeysExist() {
        let defaults = makeDefaults()
        defaults.set("whisperAPI", forKey: "io.github.airead.lingxi.voiceBackend")
        defaults.set("old-model", forKey: "io.github.airead.lingxi.voiceAPIModel")

        let settings1 = AppSettings(defaults: defaults)
        #expect(settings1.voiceASRSelection == .remote(provider: "default", model: "old-model"))

        // The user reconfigures; a second launch must not resurrect old keys.
        settings1.voiceASRProviders = []
        settings1.voiceASRSelection = .apple

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.voiceASRProviders.isEmpty)
        #expect(settings2.voiceASRSelection == .apple)
    }
}

// MARK: - Verifier with a mocked URLProtocol

/// Separate from the other mock protocols so suites can't race on a shared
/// static handler.
final class VerifyMockURLProtocol: URLProtocol {
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
struct VoiceProviderVerifierTests {

    private let provider = VoiceProvider(
        name: "test", baseURL: "https://api.example.com/v1",
        apiKey: "sk-test", models: ["model-a"]
    )

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VerifyMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func asrSuccessHitsTranscriptionsEndpoint() async throws {
        VerifyMockURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/audio/transcriptions") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            return (200, Data(#"{"text":""}"#.utf8))
        }
        try await VoiceProviderVerifier.verifyASR(
            provider: provider, model: "model-a", urlSession: makeSession()
        )
    }

    @Test func llmSuccessHitsChatCompletionsEndpoint() async throws {
        VerifyMockURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/chat/completions") == true)
            return (200, Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
        }
        try await VoiceProviderVerifier.verifyLLM(
            provider: provider, model: "model-a", urlSession: makeSession()
        )
    }

    @Test func unauthorizedThrowsAPIError() async {
        VerifyMockURLProtocol.handler = { _ in (401, Data("nope".utf8)) }
        await #expect(throws: TranscriptionError.apiError(statusCode: 401, body: "nope")) {
            try await VoiceProviderVerifier.verifyLLM(
                provider: provider, model: "model-a", urlSession: makeSession()
            )
        }
    }

    @Test func transportErrorPropagates() async {
        VerifyMockURLProtocol.handler = nil
        await #expect(throws: Error.self) {
            try await VoiceProviderVerifier.verifyASR(
                provider: provider, model: "model-a", urlSession: makeSession()
            )
        }
    }
}
