//! 16 kHz mono WAV encoding, for debug dumps and the `--record-test` gate.
//!
//! Ported from `WavEncoder.swift`. Both platforms write byte-identical files, so a WAV
//! recorded on Windows can be replayed through the macOS transcriber and back.

pub const SAMPLE_RATE: u32 = 16_000;
const HEADER_BYTES: usize = 44;

/// Encode Float32 samples to a 16-bit PCM WAV.
pub fn encode(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let num_channels: u16 = 1;
    let bits_per_sample: u16 = 16;
    let block_align = num_channels * bits_per_sample / 8;
    let byte_rate = sample_rate * block_align as u32;
    let data_size = samples.len() * block_align as usize;

    let mut out = Vec::with_capacity(HEADER_BYTES + data_size);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&((36 + data_size) as u32).to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&num_channels.to_le_bytes());
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&bits_per_sample.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data_size as u32).to_le_bytes());
    for &f in samples {
        // Swift truncates toward zero converting Double to Int16; `as i16` matches that.
        let clamped = f.clamp(-1.0, 1.0);
        out.extend_from_slice(&((clamped * 32767.0) as i16).to_le_bytes());
    }
    out
}

/// Decode a WAV written by [`encode`] back to floats. Test helper, not a general WAV reader:
/// it assumes the 44-byte header this module writes.
pub fn decode(bytes: &[u8]) -> Vec<f32> {
    if bytes.len() <= HEADER_BYTES {
        return Vec::new();
    }
    bytes[HEADER_BYTES..]
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]) as f32 / 32767.0)
        .collect()
}

/// Sample rate recorded in a header written by [`encode`].
pub fn sample_rate_of(bytes: &[u8]) -> Option<u32> {
    let field = bytes.get(24..28)?;
    Some(u32::from_le_bytes([field[0], field[1], field[2], field[3]]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_matches_the_swift_encoder() {
        let wav = encode(&[0.0, 0.5, -0.5, 1.0, -1.0], SAMPLE_RATE);
        assert_eq!(wav.len(), HEADER_BYTES + 5 * 2, "header plus data size");
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(sample_rate_of(&wav), Some(SAMPLE_RATE));
    }

    #[test]
    fn round_trips_within_quantization_error() {
        let input = [0.0, 0.5, -0.5, 1.0, -1.0, 0.123];
        let back = decode(&encode(&input, SAMPLE_RATE));
        assert_eq!(back.len(), input.len());
        for (got, want) in back.iter().zip(input.iter()) {
            assert!((got - want).abs() < 0.001, "got {got}, want {want}");
        }
    }

    #[test]
    fn clamps_out_of_range_samples() {
        let back = decode(&encode(&[9.0, -9.0], SAMPLE_RATE));
        assert!((back[0] - 1.0).abs() < 0.001);
        assert!((back[1] + 1.0).abs() < 0.001);
    }

    #[test]
    fn an_empty_recording_is_a_valid_header() {
        let wav = encode(&[], SAMPLE_RATE);
        assert_eq!(wav.len(), HEADER_BYTES);
        assert!(decode(&wav).is_empty());
    }
}
