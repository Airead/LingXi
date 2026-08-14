//
//  SpeechTranscriber.swift
//  LingXi
//

import AVFoundation
import Foundation

// MARK: - Backend selection

enum VoiceBackend: String, CaseIterable, Identifiable, Sendable {
    case apple
    case whisperAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple Speech"
        case .whisperAPI: "Whisper API"
        }
    }
}

// MARK: - Language

nonisolated enum VoiceLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto
    case chinese
    case english
    case japanese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .chinese: "中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    /// Locale identifier for SFSpeechRecognizer; nil means system locale.
    var localeIdentifier: String? {
        switch self {
        case .auto: nil
        case .chinese: "zh-CN"
        case .english: "en-US"
        case .japanese: "ja-JP"
        }
    }

    /// ISO 639-1 code for the Whisper API; nil means omit the field.
    var whisperCode: String? {
        switch self {
        case .auto: nil
        case .chinese: "zh"
        case .english: "en"
        case .japanese: "ja"
        }
    }
}

// MARK: - Errors

enum TranscriptionError: Error, Equatable {
    case notAuthorized
    case recognizerUnavailable
    case emptyAudio
    case invalidConfiguration(String)
    case apiError(statusCode: Int, body: String)
    case invalidResponse
    case timedOut
}

// MARK: - Protocols

/// Factory for transcription sessions. One session per recording.
protocol SpeechTranscriber: Sendable {
    func makeSession(language: VoiceLanguage) async throws -> any SpeechTranscriptionSession

    /// Transcribes an already-recorded 16 kHz mono Int16 WAV (as produced by
    /// `RetainedAudio`); backs re-transcription from the preview panel.
    func transcribe(wavData: Data, language: VoiceLanguage) async throws -> String
}

/// A single-use transcription session fed with audio buffers.
protocol SpeechTranscriptionSession: AnyObject, Sendable {
    /// Called from the realtime audio thread; must be fast and non-blocking.
    nonisolated func append(_ buffer: AVAudioPCMBuffer)

    /// Registers a callback invoked on an arbitrary queue with the latest
    /// partial text. Implementations without streaming support never call it.
    nonisolated func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void)

    /// Stops accepting audio and waits for the final text. Call at most once.
    func finish() async throws -> String

    /// Abandons the session. Idempotent. Must make a pending `finish()`
    /// return by throwing `CancellationError`.
    nonisolated func cancel()
}
