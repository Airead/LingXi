import Foundation
import Testing
@testable import LingXi

struct WAVEncoderTests {

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }

    private func ascii(_ data: Data, at offset: Int, count: Int) -> String {
        String(data: data.subdata(in: offset..<(offset + count)), encoding: .ascii) ?? ""
    }

    @Test func headerFields() {
        let samples: [Int16] = [0, 100, -100, 32767, -32768]
        let data = WAVEncoder.encode(samples: samples, sampleRate: 16000)

        #expect(data.count == 44 + samples.count * 2)
        #expect(ascii(data, at: 0, count: 4) == "RIFF")
        #expect(readUInt32LE(data, at: 4) == UInt32(36 + samples.count * 2))
        #expect(ascii(data, at: 8, count: 4) == "WAVE")
        #expect(ascii(data, at: 12, count: 4) == "fmt ")
        #expect(readUInt32LE(data, at: 16) == 16)          // fmt chunk size
        #expect(readUInt16LE(data, at: 20) == 1)           // PCM
        #expect(readUInt16LE(data, at: 22) == 1)           // mono
        #expect(readUInt32LE(data, at: 24) == 16000)       // sample rate
        #expect(readUInt32LE(data, at: 28) == 32000)       // byte rate
        #expect(readUInt16LE(data, at: 32) == 2)           // block align
        #expect(readUInt16LE(data, at: 34) == 16)          // bits per sample
        #expect(ascii(data, at: 36, count: 4) == "data")
        #expect(readUInt32LE(data, at: 40) == UInt32(samples.count * 2))
    }

    @Test func samplesAreLittleEndian() {
        let data = WAVEncoder.encode(samples: [0x1234, -2], sampleRate: 16000)
        #expect(data[44] == 0x34)
        #expect(data[45] == 0x12)
        // -2 == 0xFFFE
        #expect(data[46] == 0xFE)
        #expect(data[47] == 0xFF)
    }

    @Test func emptySamples() {
        let data = WAVEncoder.encode(samples: [], sampleRate: 16000)
        #expect(data.count == 44)
        #expect(readUInt32LE(data, at: 4) == 36)
        #expect(readUInt32LE(data, at: 40) == 0)
    }

    @Test func customSampleRate() {
        let data = WAVEncoder.encode(samples: [1], sampleRate: 48000)
        #expect(readUInt32LE(data, at: 24) == 48000)
        #expect(readUInt32LE(data, at: 28) == 96000)
    }
}

struct WAVDecoderTests {

    @Test func roundTripsEncodedSamples() {
        let samples: [Int16] = [0, 100, -100, 32767, -32768, 0x1234]
        let data = WAVEncoder.encode(samples: samples, sampleRate: 16000)
        #expect(WAVDecoder.decodeSamples(data) == samples)
    }

    @Test func rejectsNonWAVData() {
        #expect(WAVDecoder.decodeSamples(Data("not a wav at all, truly".utf8).padded(to: 60)) == nil)
        #expect(WAVDecoder.decodeSamples(Data()) == nil)
        // Header-only WAV (no samples) has nothing to decode.
        #expect(WAVDecoder.decodeSamples(WAVEncoder.encode(samples: [], sampleRate: 16000)) == nil)
    }

    @Test func skipsUnknownChunksBeforeData() {
        // RIFF + WAVE + fmt + a bogus "LIST" chunk + data.
        var data = WAVEncoder.encode(samples: [7, -7], sampleRate: 16000)
        // Splice a LIST chunk between fmt (ends at 36) and data.
        var list = Data("LIST".utf8)
        list.append(contentsOf: [4, 0, 0, 0]) // size 4 LE
        list.append(contentsOf: [1, 2, 3, 4])
        data.insert(contentsOf: list, at: 36)
        #expect(WAVDecoder.decodeSamples(data) == [7, -7])
    }

    @Test func truncatedDataChunkIsClamped() {
        var data = WAVEncoder.encode(samples: [1, 2, 3], sampleRate: 16000)
        data.removeLast(2) // drop the last sample's bytes
        #expect(WAVDecoder.decodeSamples(data) == [1, 2])
    }
}

private extension Data {
    func padded(to count: Int) -> Data {
        var copy = self
        while copy.count < count { copy.append(0) }
        return copy
    }
}
