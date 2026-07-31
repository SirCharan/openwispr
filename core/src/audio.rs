//! Turning whatever the microphone gives us into what Whisper wants: 16 kHz mono Float32.
//!
//! Ported from `ResamplingBuffer.swift` and `MicLevelMeter.swift`. macOS gets resampling free
//! from `AVAudioConverter`; Windows has no equivalent, so the conversion is written out here.
//! Keeping it in `core` means it is testable without a microphone, on either platform.

use crate::wav::SAMPLE_RATE;

/// Downmix interleaved frames to mono by averaging channels.
pub fn to_mono(interleaved: &[f32], channels: u16) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    let n = channels as usize;
    interleaved
        .chunks(n)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect()
}

/// Resample mono samples to 16 kHz.
///
/// Downsampling averages each output sample's input window. That box filter is doing two jobs:
/// decimating, and low-passing so the discarded high frequencies do not alias back into speech.
/// Plain interpolation would skip the second job and add a metallic edge to every recording.
/// Upsampling has nothing to remove, so it interpolates linearly.
pub fn resample_to_16k(mono: &[f32], in_rate: u32) -> Vec<f32> {
    if mono.is_empty() || in_rate == 0 || in_rate == SAMPLE_RATE {
        return mono.to_vec();
    }
    let ratio = in_rate as f64 / SAMPLE_RATE as f64;
    let out_len = (mono.len() as f64 / ratio).floor() as usize;
    let mut out = Vec::with_capacity(out_len);

    if ratio > 1.0 {
        for j in 0..out_len {
            let start = (j as f64 * ratio) as usize;
            let end = (((j + 1) as f64 * ratio) as usize)
                .min(mono.len())
                .max(start + 1);
            let window = &mono[start..end];
            out.push(window.iter().sum::<f32>() / window.len() as f32);
        }
    } else {
        for j in 0..out_len {
            let pos = j as f64 * ratio;
            let i = pos as usize;
            let frac = (pos - i as f64) as f32;
            let a = mono[i];
            let b = *mono.get(i + 1).unwrap_or(&a);
            out.push(a + (b - a) * frac);
        }
    }
    out
}

/// Root mean square of a slice. 0 for an empty slice.
pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    (samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32).sqrt()
}

/// Map RMS to the 0 to 1 range the level meter draws.
///
/// Speech sits around 0.02 to 0.3 RMS, so the x12 gain puts normal talking in the upper half
/// of the meter. Matches the scaling in `MicLevelMeter.swift`.
pub fn level_from_rms(rms: f32) -> f64 {
    (rms as f64 * 12.0).min(1.0)
}

/// Exponential smoothing for the displayed level, so the meter does not strobe per buffer.
pub fn smooth_level(previous: f64, target: f64) -> f64 {
    previous * 0.6 + target * 0.4
}

/// Accumulates captured audio already converted to 16 kHz mono.
///
/// The platform layer owns the audio callback and the lock; this type owns the arithmetic.
#[derive(Debug, Default)]
pub struct SampleBuffer {
    samples: Vec<f32>,
}

impl SampleBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn clear(&mut self) {
        self.samples.clear();
    }

    /// Convert one captured buffer and append it.
    pub fn append(&mut self, interleaved: &[f32], in_rate: u32, channels: u16) {
        let mono = to_mono(interleaved, channels);
        self.samples.extend(resample_to_16k(&mono, in_rate));
    }

    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    pub fn len(&self) -> usize {
        self.samples.len()
    }

    /// Everything captured so far, leaving the buffer intact.
    pub fn snapshot(&self) -> Vec<f32> {
        self.samples.clone()
    }

    /// The trailing `seconds`, leaving the buffer intact.
    pub fn tail(&self, seconds: f64) -> Vec<f32> {
        let n = ((seconds * SAMPLE_RATE as f64) as usize).min(self.samples.len());
        self.samples[self.samples.len() - n..].to_vec()
    }

    /// Take everything and clear, for chunked live transcription.
    pub fn drain(&mut self) -> Vec<f32> {
        std::mem::take(&mut self.samples)
    }

    pub fn buffered_seconds(&self) -> f64 {
        self.samples.len() as f64 / SAMPLE_RATE as f64
    }

    /// RMS of the trailing `seconds`. A low value means the speaker paused.
    pub fn tail_rms(&self, seconds: f64) -> f32 {
        rms(&self.tail(seconds))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stereo_averages_to_mono() {
        assert_eq!(to_mono(&[1.0, 0.0, 0.5, 0.5], 2), vec![0.5, 0.5]);
        assert_eq!(to_mono(&[0.25, 0.75], 1), vec![0.25, 0.75]);
    }

    #[test]
    fn the_common_rate_decimates_by_three() {
        // 48 kHz is what almost every Windows input device reports.
        let input: Vec<f32> = (0..48_000).map(|i| (i % 3) as f32).collect();
        let out = resample_to_16k(&input, 48_000);
        assert_eq!(out.len(), 16_000);
        // each output sample averages 0, 1, 2
        for s in &out {
            assert!((s - 1.0).abs() < 0.001, "got {s}");
        }
    }

    #[test]
    fn a_matching_rate_is_passed_through_untouched() {
        let input = vec![0.1, 0.2, 0.3];
        assert_eq!(resample_to_16k(&input, SAMPLE_RATE), input);
    }

    #[test]
    fn downsampling_preserves_duration() {
        for rate in [22_050, 44_100, 48_000, 96_000] {
            let one_second: Vec<f32> = vec![0.5; rate as usize];
            let out = resample_to_16k(&one_second, rate);
            let seconds = out.len() as f64 / SAMPLE_RATE as f64;
            assert!(
                (seconds - 1.0).abs() < 0.01,
                "{rate} Hz produced {seconds} s"
            );
        }
    }

    #[test]
    fn upsampling_preserves_duration() {
        let one_second: Vec<f32> = vec![0.5; 8_000];
        let out = resample_to_16k(&one_second, 8_000);
        assert_eq!(out.len(), 16_000);
    }

    #[test]
    fn a_downsampled_tone_keeps_its_amplitude() {
        // 440 Hz at 48 kHz survives the trip to 16 kHz: well under the 8 kHz Nyquist limit.
        let input: Vec<f32> = (0..48_000)
            .map(|i| (i as f32 * 440.0 * std::f32::consts::TAU / 48_000.0).sin())
            .collect();
        let out = resample_to_16k(&input, 48_000);
        let input_rms = rms(&input);
        let out_rms = rms(&out);
        assert!(
            (out_rms - input_rms).abs() < 0.05,
            "rms drifted: {input_rms} to {out_rms}"
        );
    }

    #[test]
    fn empty_input_is_handled() {
        assert!(resample_to_16k(&[], 48_000).is_empty());
        assert_eq!(rms(&[]), 0.0);
        assert_eq!(resample_to_16k(&[0.5], 0), vec![0.5]);
    }

    #[test]
    fn rms_and_level_mapping() {
        assert!((rms(&[0.5, -0.5]) - 0.5).abs() < 0.001);
        assert_eq!(level_from_rms(0.0), 0.0);
        assert_eq!(level_from_rms(1.0), 1.0, "loud input clamps at 1");
        assert!((level_from_rms(0.05) - 0.6).abs() < 0.001);
    }

    #[test]
    fn smoothing_moves_toward_the_target() {
        let mut level = 0.0;
        for _ in 0..20 {
            level = smooth_level(level, 1.0);
        }
        assert!(level > 0.99, "should approach the target, got {level}");
        assert!(smooth_level(1.0, 0.0) < 1.0, "and fall back down");
    }

    #[test]
    fn the_buffer_accumulates_and_drains() {
        let mut buf = SampleBuffer::new();
        assert!(buf.is_empty());
        // 48 kHz stereo, one second
        let frames: Vec<f32> = vec![0.5; 48_000 * 2];
        buf.append(&frames, 48_000, 2);
        assert_eq!(buf.len(), 16_000);
        assert!((buf.buffered_seconds() - 1.0).abs() < 0.01);
        assert!((buf.tail_rms(0.5) - 0.5).abs() < 0.01);
        assert_eq!(buf.tail(0.5).len(), 8_000);

        let taken = buf.drain();
        assert_eq!(taken.len(), 16_000);
        assert!(buf.is_empty());
        assert_eq!(buf.tail_rms(1.0), 0.0, "an empty buffer is silent");
    }

    #[test]
    fn a_tail_longer_than_the_buffer_returns_what_exists() {
        let mut buf = SampleBuffer::new();
        buf.append(&vec![0.5; 1_600], SAMPLE_RATE, 1);
        assert_eq!(buf.tail(10.0).len(), 1_600);
    }
}
