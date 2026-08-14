//
//  VoiceActivityModel.swift
//  LingXi
//

import Foundation
import Observation

/// Observable voice input activity state, driving the menu bar icon.
@Observable
@MainActor
final class VoiceActivityModel {
    enum Phase {
        case idle
        case recording
        case transcribing
        case enhancing
    }

    var phase: Phase = .idle

    /// Throttled microphone RMS level (0...~1) while recording, for the HUD.
    var level: Double = 0

    /// Latest streaming partial text (Apple backend only), for the HUD.
    var partialText: String = ""

    var symbolName: String {
        switch phase {
        case .idle: "atom"
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .enhancing: "sparkles"
        }
    }
}
