//
//  VoiceAudioRecorder.swift
//  LingXi
//

import AVFoundation
import Foundation

enum AudioRecorderError: Error {
    case noInputDevice
    case alreadyRunning
}

/// Abstraction over microphone capture so tests can inject a fake.
protocol AudioRecording: Sendable {
    /// Starts capturing; `sink` is invoked on the realtime audio thread and
    /// must be fast and non-blocking. `onConfigurationChange` fires when the
    /// audio engine configuration changes mid-recording (e.g. device switch).
    func start(
        sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) async throws

    /// Stops capturing. Idempotent.
    func stop() async
}

actor VoiceAudioRecorder: AudioRecording {
    private var engine: AVAudioEngine?
    private var configObserver: (any NSObjectProtocol)?

    func start(
        sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws {
        guard engine == nil else { throw AudioRecorderError.alreadyRunning }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink(buffer)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            onConfigurationChange()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            removeObserver()
            throw error
        }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        removeObserver()
    }

    private func removeObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }
}
