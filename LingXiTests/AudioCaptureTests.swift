import AVFoundation
import Foundation
import Testing
@testable import LingXi

@MainActor
struct RetainedAudioTests {

    /// A mono float buffer at 48 kHz filled with a quiet sine wave.
    private func makeBuffer(frames: AVAudioFrameCount = 4800) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = sinf(Float(i) * 0.05) * 0.25
        }
        return buffer
    }

    /// 48 kHz input resamples to 16 kHz: 1/3 of the frames, as WAV bytes.
    private func expectedWAVSize(inputFrames: Int) -> Int {
        44 + (inputFrames / 3) * 2
    }

    @Test func producesValidWAVFromRetainedBuffers() async throws {
        let audio = RetainedAudio()
        audio.append(makeBuffer())
        audio.append(makeBuffer())
        audio.stopAccepting()

        let data = try await audio.wavData()
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data.subdata(in: 8..<12) == Data("WAVE".utf8))
        // Resampler edges may add or drop a few frames.
        let expected = expectedWAVSize(inputFrames: 9600)
        #expect(abs(data.count - expected) < 200)
    }

    @Test func emptyAudioThrows() async {
        let audio = RetainedAudio()
        audio.stopAccepting()
        await #expect(throws: TranscriptionError.emptyAudio) {
            _ = try await audio.wavData()
        }
    }

    @Test func appendAfterStopIsIgnored() async throws {
        let audio = RetainedAudio()
        audio.append(makeBuffer())
        audio.stopAccepting()
        audio.append(makeBuffer())
        audio.append(makeBuffer())

        let data = try await audio.wavData()
        // Only the first buffer counts: ~1600 samples, not ~4800.
        let expected = expectedWAVSize(inputFrames: 4800)
        #expect(abs(data.count - expected) < 200)
    }

    @Test func wavDataIsMemoized() async throws {
        let audio = RetainedAudio()
        audio.append(makeBuffer())

        let first = try await audio.wavData()
        let second = try await audio.wavData()
        #expect(first == second)
    }

    @Test func zeroLengthBufferIsSkipped() async {
        let audio = RetainedAudio()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        audio.append(empty) // frameLength == 0: the copy helper rejects it
        await #expect(throws: TranscriptionError.emptyAudio) {
            _ = try await audio.wavData()
        }
    }
}
