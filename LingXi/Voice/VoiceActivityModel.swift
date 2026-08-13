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
    }

    var phase: Phase = .idle

    var symbolName: String {
        switch phase {
        case .idle: "atom"
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        }
    }
}
