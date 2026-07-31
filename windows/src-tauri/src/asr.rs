//! whisper.cpp transcription, behind the `asr` cargo feature.
//!
//! Verified against whisper-rs 0.16.0's source. MODEL FORMAT: whisper.cpp requires the
//! legacy ggml container (`GGML_FILE_MAGIC` 0x67676d6c, i.e. `ggml-base.en.bin`). A true
//! GGUF file is rejected by whisper.cpp's loader with "invalid model data (bad magic)",
//! which surfaces here as `WhisperError::InitError`. Any quantization of a ggml model
//! (q4_0/q5_0/q8_0/fp16/fp32) loads fine.

use std::path::Path;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

/// Transcribe 16 kHz mono f32 PCM. `language: None` => auto-detect ("auto" is equivalent).
/// `threads` is clamped to >= 1. Errors are flattened to String (WhisperError: Display).
pub fn transcribe(
    model_path: &Path,
    samples: &[f32],
    language: Option<&str>,
    translate: bool,
    threads: i32,
) -> Result<String, String> {
    // Route whisper.cpp/GGML's stderr chatter into the log/tracing backends
    // (or nowhere, if neither feature is on). Idempotent.
    whisper_rs::install_logging_hooks();

    // GPU use is a plain bool field whose Default is cfg!(feature = "_gpu"), i.e. false
    // unless a whisper-rs gpu feature (cuda/vulkan/...) is compiled in. Left at default so
    // enabling `asr-gpu` later flips it with no code change here.
    let cparams = WhisperContextParameters::default();

    let ctx = WhisperContext::new_with_params(model_path, cparams).map_err(|e| {
        format!(
            "whisper: failed to load model {}: {e} \
             (must be a whisper.cpp ggml model, not GGUF)",
            model_path.display()
        )
    })?;

    let mut state = ctx
        .create_state()
        .map_err(|e| format!("whisper: create_state failed: {e}"))?;

    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_n_threads(threads.max(1));
    params.set_translate(translate);
    // set_language panics on an interior NUL byte, so reject that here rather than in FFI.
    if let Some(l) = language {
        if l.contains('\0') {
            return Err("whisper: language contains a NUL byte".into());
        }
    }
    params.set_language(language);
    // There is no single "quiet" switch — all four are separate.
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);

    // Empty input is rejected by the crate itself (WhisperError::NoSamples).
    state
        .full(params, samples)
        .map_err(|e| format!("whisper: inference failed: {e}"))?;

    let mut out = String::new();
    for segment in state.as_iter() {
        // to_str_lossy avoids an error on a mid-UTF8-boundary segment; Display would panic
        // on a null pointer instead of returning Err.
        let text = segment
            .to_str_lossy()
            .map_err(|e| format!("whisper: segment text unavailable: {e}"))?;
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(text);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    // The cheapest real check that needs no model file. It still needs CMake and a C++
    // toolchain, because compiling this crate with `--features asr` builds whisper.cpp.
    #[test]
    fn missing_model_is_an_error_not_a_panic() {
        let err = transcribe(
            Path::new("/nonexistent/ggml-tiny.bin"),
            &[0.0f32; 16000],
            None,
            false,
            2,
        )
        .unwrap_err();
        assert!(err.starts_with("whisper: failed to load model"), "{err}");
    }
}
