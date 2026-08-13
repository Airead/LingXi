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
