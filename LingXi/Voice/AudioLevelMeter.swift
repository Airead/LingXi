//
//  AudioLevelMeter.swift
//  LingXi
//

import AVFoundation
import Foundation
import QuartzCore

/// Computes a throttled RMS level from audio buffers on the realtime audio
/// thread (multiply-add only, no allocation) and delivers it to the main
/// actor. One instance per recording session.
nonisolated final class AudioLevelMeter: @unchecked Sendable {
    /// Minimum interval between emissions.
    struct Throttler {
        let interval: TimeInterval
        private var last: TimeInterval = -.infinity

        init(interval: TimeInterval) {
            self.interval = interval
        }

        mutating func shouldFire(at now: TimeInterval) -> Bool {
            guard now - last >= interval else { return false }
            last = now
            return true
        }
    }

    private let onLevel: @MainActor (Double) -> Void
    // Touched only from the audio thread; buffers arrive serially.
    private var throttler: Throttler

    init(throttleInterval: TimeInterval = 0.1, onLevel: @escaping @MainActor (Double) -> Void) {
        self.throttler = Throttler(interval: throttleInterval)
        self.onLevel = onLevel
    }

    nonisolated func ingest(_ buffer: AVAudioPCMBuffer, now: TimeInterval = CACurrentMediaTime()) {
        guard throttler.shouldFire(at: now) else { return }
        let level = Self.rms(of: buffer)
        DispatchQueue.main.async { [onLevel] in
            MainActor.assumeIsolated { onLevel(level) }
        }
    }

    /// Root mean square of the first channel, 0...~1 for float PCM input.
    nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData?[0] else { return 0 }
        var sum = 0.0
        for i in 0..<frames {
            let sample = Double(channel[i])
            sum += sample * sample
        }
        return (sum / Double(frames)).squareRoot()
    }
}
