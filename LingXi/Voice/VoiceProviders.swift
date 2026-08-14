//
//  VoiceProviders.swift
//  LingXi
//

import Foundation

// MARK: - Provider model

/// An OpenAI-compatible endpoint offering one or more models.
/// Used both for ASR (audio/transcriptions) and LLM (chat/completions).
nonisolated struct VoiceProvider: Codable, Sendable, Equatable, Identifiable {
    /// Unique user-chosen identifier, e.g. "groq", "ollama".
    var name: String
    var baseURL: String
    var apiKey: String
    var models: [String]

    var id: String { name }
}

// MARK: - Selections

/// Which speech recognizer to use: on-device Apple Speech or a remote
/// provider/model pair from `voiceASRProviders`.
nonisolated enum ASRSelection: Codable, Sendable, Equatable, Hashable {
    case apple
    case remote(provider: String, model: String)
}

/// Which chat model to use for enhancement, referencing `voiceLLMProviders`.
nonisolated struct LLMSelection: Codable, Sendable, Equatable, Hashable {
    var provider: String
    var model: String
}

// MARK: - Resolution (pure, unit-testable)

/// Resolves a selection against the configured provider list, degrading
/// gracefully when the referenced provider or model no longer exists.
nonisolated enum VoiceProviderResolver {
    enum ASRResolution: Equatable {
        case apple
        case remote(provider: VoiceProvider, model: String)
    }

    /// Missing provider falls back to Apple Speech; a provider whose model
    /// list no longer contains the selected model falls back to its first model.
    static func resolveASR(selection: ASRSelection, providers: [VoiceProvider]) -> ASRResolution {
        switch selection {
        case .apple:
            return .apple
        case .remote(let providerName, let model):
            guard let provider = providers.first(where: { $0.name == providerName }) else {
                return .apple
            }
            if provider.models.contains(model) {
                return .remote(provider: provider, model: model)
            }
            guard let fallback = provider.models.first else { return .apple }
            return .remote(provider: provider, model: fallback)
        }
    }

    /// Missing provider or model falls back to the first available pair;
    /// nil when no provider with at least one model exists.
    static func resolveLLM(
        selection: LLMSelection,
        providers: [VoiceProvider]
    ) -> (provider: VoiceProvider, model: String)? {
        if let provider = providers.first(where: { $0.name == selection.provider }) {
            if provider.models.contains(selection.model) {
                return (provider, selection.model)
            }
            if let fallback = provider.models.first {
                return (provider, fallback)
            }
        }
        guard let provider = providers.first(where: { !$0.models.isEmpty }),
              let model = provider.models.first else {
            return nil
        }
        return (provider, model)
    }
}

// MARK: - Verification

/// Sends a minimal real request to a provider to check URL/key/model validity.
nonisolated enum VoiceProviderVerifier {
    /// Posts 0.5 s of silence to `/audio/transcriptions`.
    static func verifyASR(
        provider: VoiceProvider,
        model: String,
        urlSession: URLSession = .shared
    ) async throws {
        let configuration = WhisperAPIConfiguration(
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            model: model
        )
        let silence = WAVEncoder.encode(
            samples: [Int16](repeating: 0, count: 8000),
            sampleRate: 16000
        )
        let request = try WhisperRequestBuilder.makeRequest(
            configuration: configuration,
            languageCode: nil,
            wavData: silence
        )
        try await perform(request, urlSession: urlSession)
    }

    /// Posts a one-word completion to `/chat/completions`.
    static func verifyLLM(
        provider: VoiceProvider,
        model: String,
        urlSession: URLSession = .shared
    ) async throws {
        let configuration = LLMEnhancerConfiguration(
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            model: model,
            systemPrompt: "Reply with the single word OK."
        )
        let request = try EnhanceRequestBuilder.makeRequest(configuration: configuration, text: "ping")
        try await perform(request, urlSession: urlSession)
    }

    private static func perform(_ request: URLRequest, urlSession: URLSession) async throws {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw TranscriptionError.apiError(statusCode: http.statusCode, body: body)
        }
    }
}
