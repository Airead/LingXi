//
//  AudioCapture.swift
//  LingXi
//

@preconcurrency import AVFoundation
import Foundation

// MARK: - Buffer conversion helpers

/// Buffer copy and format conversion shared by the Whisper upload path and
/// the preview panel's retained audio.
nonisolated enum AudioBufferConversion {
    /// Copies a tap buffer; the tap may reuse the buffer after the callback
    /// returns, so retained buffers must be copies.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (srcBuffer, dstBuffer) in zip(src, dst) {
            guard let srcData = srcBuffer.mData, let dstData = dstBuffer.mData else { continue }
            memcpy(dstData, srcData, Int(min(srcBuffer.mDataByteSize, dstBuffer.mDataByteSize)))
        }
        return copy
    }

    /// Converts recorded buffers (any input format) to 16 kHz mono Int16.
    static func convertToInt16Mono16k(_ buffers: [AVAudioPCMBuffer]) throws -> [Int16] {
        guard let sourceFormat = buffers.first?.format,
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw TranscriptionError.emptyAudio
        }

        var samples: [Int16] = []
        var inputIndex = 0
        var reachedEnd = false
        while !reachedEnd {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else {
                throw TranscriptionError.emptyAudio
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if inputIndex < buffers.count {
                    let next = buffers[inputIndex]
                    inputIndex += 1
                    outStatus.pointee = .haveData
                    return next
                }
                outStatus.pointee = .endOfStream
                return nil
            }
            switch status {
            case .haveData, .inputRanDry:
                if let channel = output.int16ChannelData, output.frameLength > 0 {
                    samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
                }
                if status == .inputRanDry { reachedEnd = true }
            case .endOfStream:
                reachedEnd = true
            case .error:
                throw conversionError ?? TranscriptionError.emptyAudio
            @unknown default:
                reachedEnd = true
            }
        }
        return samples
    }
}

// MARK: - Retained audio (test seam)

/// Keeps a recording's audio alive for the preview session so the panel can
/// play it back, save it and re-transcribe it with another ASR model.
protocol AudioRetaining: AnyObject, Sendable {
    /// Called from the realtime audio thread; must be fast and non-blocking.
    nonisolated func append(_ buffer: AVAudioPCMBuffer)
    /// Stops accepting buffers once the recording ends.
    nonisolated func stopAccepting()
    /// The recording as a 16 kHz mono Int16 WAV. The first call converts (and
    /// releases the raw buffers); later calls return the memoized result.
    /// Throws `TranscriptionError.emptyAudio` when nothing was recorded.
    func wavData() async throws -> Data
}

/// Buffer accumulation is lock-protected because append() runs on the
/// realtime audio thread; conversion happens off the main actor.
final class RetainedAudio: AudioRetaining, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var accepting = true
    private var conversion: Task<Data, Error>?

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = AudioBufferConversion.copy(buffer) else { return }
        lock.withLock {
            guard accepting else { return }
            buffers.append(copy)
        }
    }

    nonisolated func stopAccepting() {
        lock.withLock { accepting = false }
    }

    func wavData() async throws -> Data {
        if let conversion { return try await conversion.value }
        let task = Task { try await performConversion() }
        conversion = task
        return try await task.value
    }

    @concurrent
    private func performConversion() async throws -> Data {
        let recorded: [AVAudioPCMBuffer] = lock.withLock {
            accepting = false
            let taken = buffers
            buffers.removeAll()
            return taken
        }
        guard !recorded.isEmpty else { throw TranscriptionError.emptyAudio }
        let samples = try AudioBufferConversion.convertToInt16Mono16k(recorded)
        guard !samples.isEmpty else { throw TranscriptionError.emptyAudio }
        return WAVEncoder.encode(samples: samples, sampleRate: 16000)
    }
}
