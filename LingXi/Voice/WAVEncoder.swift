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

/// Extracts the PCM samples from a 16-bit mono WAV as produced by
/// `WAVEncoder`; used to feed retained audio back into Apple Speech.
nonisolated enum WAVDecoder {
    static func decodeSamples(_ data: Data) -> [Int16]? {
        guard data.count > 44,
              data.prefix(4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            return nil
        }
        // Walk the chunks to find "data"; other chunks (fmt, lists) are skipped.
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = data.subdata(in: offset..<(offset + 4))
            let chunkSize = Int(readLE32(data, at: offset + 4))
            let payloadStart = offset + 8
            if chunkID == Data("data".utf8) {
                let payloadEnd = min(payloadStart + chunkSize, data.count)
                let byteCount = (payloadEnd - payloadStart) & ~1
                guard byteCount > 0 else { return nil }
                var samples = [Int16](repeating: 0, count: byteCount / 2)
                _ = samples.withUnsafeMutableBytes { destination in
                    data.copyBytes(to: destination, from: payloadStart..<(payloadStart + byteCount))
                }
                return samples
            }
            offset = payloadStart + chunkSize + (chunkSize & 1)
        }
        return nil
    }

    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            data.copyBytes(to: destination, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: value)
    }
}
