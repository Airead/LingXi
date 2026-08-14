import AVFoundation
import Foundation
import Testing
@testable import LingXi

struct AudioLevelMeterTests {

    private func makeBuffer(amplitude: Float, frames: AVAudioFrameCount = 1600) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = sin(Float(i) * 0.1) * amplitude
        }
        return buffer
    }

    // MARK: - RMS

    @Test func rmsOfSineIsAmplitudeOverSqrt2() {
        let rms = AudioLevelMeter.rms(of: makeBuffer(amplitude: 0.5))
        // RMS of a sine wave is amplitude / √2 ≈ 0.3536.
        #expect(abs(rms - 0.5 / 2.0.squareRoot()) < 0.01)
    }

    @Test func rmsOfSilenceIsZero() {
        #expect(AudioLevelMeter.rms(of: makeBuffer(amplitude: 0)) == 0)
    }

    @Test func rmsOfEmptyBufferIsZero() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        #expect(AudioLevelMeter.rms(of: buffer) == 0)
    }

    // MARK: - Throttling

    @Test func throttlerLimitsEmissionRate() {
        var throttler = AudioLevelMeter.Throttler(interval: 0.1)
        let fired = [0.0, 0.05, 0.099, 0.1, 0.15, 0.25].map { throttler.shouldFire(at: $0) }
        #expect(fired == [true, false, false, true, false, true])
    }

    // MARK: - Delivery

    @MainActor
    @Test func deliversThrottledLevelOnMainActor() async {
        final class Collector: @unchecked Sendable {
            @MainActor var levels: [Double] = []
        }
        let collector = Collector()
        let meter = AudioLevelMeter(throttleInterval: 0.1) { level in
            collector.levels.append(level)
        }

        let buffer = makeBuffer(amplitude: 0.5)
        meter.ingest(buffer, now: 0.0)   // fires
        meter.ingest(buffer, now: 0.05)  // throttled
        meter.ingest(buffer, now: 0.2)   // fires

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while collector.levels.count < 2, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(collector.levels.count == 2)
        #expect(collector.levels.allSatisfy { abs($0 - 0.5 / 2.0.squareRoot()) < 0.01 })
    }
}
