//
//  WAVEncoder.swift
//  LingXi
//

import Foundation

/// Encodes 16-bit mono PCM samples into a WAV container (44-byte header).
nonisolated enum WAVEncoder {
    static func encode(samples: [Int16], sampleRate: UInt32) -> Data {
        let byteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data(capacity: 44 + Int(byteCount))

        data.append(Data("RIFF".utf8))
        appendLE(&data, 36 + byteCount)
        data.append(Data("WAVE".utf8))

        data.append(Data("fmt ".utf8))
        appendLE(&data, UInt32(16))            // fmt chunk size
        appendLE(&data, UInt16(1))             // PCM format
        appendLE(&data, UInt16(1))             // mono
        appendLE(&data, sampleRate)
        appendLE(&data, sampleRate * 2)        // byte rate
        appendLE(&data, UInt16(2))             // block align
        appendLE(&data, UInt16(16))            // bits per sample

        data.append(Data("data".utf8))
        appendLE(&data, byteCount)
        samples.withUnsafeBufferPointer { buffer in
            data.append(UnsafeRawBufferPointer(buffer).bindMemory(to: UInt8.self))
        }
        return data
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
