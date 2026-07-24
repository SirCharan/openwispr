import Foundation

/// Encode 16 kHz mono Float32 samples to a 16-bit PCM WAV file.
/// Used for debug dumps and the --record-test gate.
enum WavEncoder {
    static func encode(_ samples: [Float], sampleRate: Int = 16000) -> Data {
        let numChannels = 1
        let bitsPerSample = 16
        let blockAlign = numChannels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = samples.count * blockAlign

        var data = Data(capacity: 44 + dataSize)
        func str(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(numChannels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        str("data"); u32(UInt32(dataSize))
        for f in samples {
            let clamped = max(-1.0, min(1.0, f))
            u16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }

    /// Assert-based self-check (ponytail: one runnable check for the money/parse path).
    static func selfTest() {
        let wav = encode([0, 0.5, -0.5, 1.0, -1.0], sampleRate: 16000)
        assert(wav.count == 44 + 5 * 2, "header+data size wrong: \(wav.count)")
        assert(Array(wav[0..<4]) == Array("RIFF".utf8), "missing RIFF")
        assert(Array(wav[8..<12]) == Array("WAVE".utf8), "missing WAVE")
        // sampleRate field at offset 24, little-endian == 16000
        let sr = UInt32(wav[24]) | UInt32(wav[25]) << 8 | UInt32(wav[26]) << 16 | UInt32(wav[27]) << 24
        assert(sr == 16000, "sampleRate wrong: \(sr)")
        print("WavEncoder.selfTest PASS")
    }
}
