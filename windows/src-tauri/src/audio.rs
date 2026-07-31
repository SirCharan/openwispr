//! Microphone capture. WASAPI on Windows, via cpal.
//!
//! All the arithmetic (downmix, resample, RMS, level) lives in `openwispr_core::audio` so it
//! can be tested without a microphone. This module owns only the device and the callback.
//!
//! The cpal `Stream` is not `Send` on every backend, so it never leaves the thread that built
//! it: `start` spawns a capture thread that owns the stream and parks until told to stop.
//! Everything shared with the caller goes through `Arc<Shared>`.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use openwispr_core::audio::{level_from_rms, rms, smooth_level, SampleBuffer};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

#[derive(Debug, Default)]
struct Shared {
    buffer: Mutex<SampleBuffer>,
    level: Mutex<f64>,
    /// Set when the device fails mid-recording (unplugged, format change, driver reset).
    error: Mutex<Option<String>>,
}

pub struct Recorder {
    shared: Arc<Shared>,
    stop: Option<Sender<()>>,
    thread: Option<JoinHandle<()>>,
}

impl Default for Recorder {
    fn default() -> Self {
        Self::new()
    }
}

impl Recorder {
    pub fn new() -> Self {
        Self {
            shared: Arc::new(Shared::default()),
            stop: None,
            thread: None,
        }
    }

    pub fn is_recording(&self) -> bool {
        self.thread.is_some()
    }

    /// Names of the available input devices, default first.
    pub fn input_devices() -> Result<Vec<String>, String> {
        let host = cpal::default_host();
        let default = host
            .default_input_device()
            .and_then(|d| device_name(&d))
            .unwrap_or_default();
        let mut names: Vec<String> = host
            .input_devices()
            .map_err(|e| format!("cannot list input devices: {}", describe(&e)))?
            .filter_map(|d| device_name(&d))
            .collect();
        names.sort();
        names.dedup();
        // Put the default first: onboarding offers it as the pre-selected choice.
        if let Some(i) = names.iter().position(|n| *n == default) {
            let d = names.remove(i);
            names.insert(0, d);
        }
        Ok(names)
    }

    /// Begin capturing. `device_name` of `None` uses the system default input.
    ///
    /// Returns the error the device reported rather than a generic message: onboarding shows it
    /// verbatim, because "device in use by another application" and "no input device" need
    /// different actions from the user.
    pub fn start(&mut self, device_name: Option<String>) -> Result<(), String> {
        if self.is_recording() {
            return Ok(()); // a second stream on one device would fight the first
        }
        self.shared.buffer.lock().unwrap().clear();
        *self.shared.level.lock().unwrap() = 0.0;
        *self.shared.error.lock().unwrap() = None;

        let (stop_tx, stop_rx) = channel::<()>();
        let (ready_tx, ready_rx) = channel::<Result<(), String>>();
        let shared = Arc::clone(&self.shared);

        let thread = std::thread::Builder::new()
            .name("openwispr-capture".into())
            .spawn(move || capture_loop(shared, device_name, ready_tx, stop_rx))
            .map_err(|e| format!("cannot spawn the capture thread: {e}"))?;

        // Wait for the stream to actually open, so a failure surfaces here and not silently later.
        match ready_rx.recv() {
            Ok(Ok(())) => {
                self.stop = Some(stop_tx);
                self.thread = Some(thread);
                Ok(())
            }
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(e)
            }
            Err(_) => {
                let _ = thread.join();
                Err("the capture thread stopped before reporting readiness".into())
            }
        }
    }

    /// Stop capturing and return everything recorded, as 16 kHz mono.
    pub fn stop(&mut self) -> Vec<f32> {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        let mut buffer = self.shared.buffer.lock().unwrap();
        let samples = buffer.snapshot();
        buffer.clear();
        samples
    }

    /// Smoothed 0 to 1 level for the meter.
    pub fn level(&self) -> f64 {
        *self.shared.level.lock().unwrap()
    }

    pub fn buffered_seconds(&self) -> f64 {
        self.shared.buffer.lock().unwrap().buffered_seconds()
    }

    /// An error reported by the device after recording began, if any.
    pub fn error(&self) -> Option<String> {
        self.shared.error.lock().unwrap().clone()
    }
}

fn capture_loop(
    shared: Arc<Shared>,
    device_name: Option<String>,
    ready: Sender<Result<(), String>>,
    stop: Receiver<()>,
) {
    let stream = match open_stream(&shared, device_name) {
        Ok(s) => s,
        Err(e) => {
            let _ = ready.send(Err(e));
            return;
        }
    };
    if let Err(e) = stream.play() {
        let _ = ready.send(Err(format!("cannot start the input stream: {e}")));
        return;
    }
    let _ = ready.send(Ok(()));

    // Park until stop is signalled. Dropping the stream here closes the device.
    let _ = stop.recv();
    drop(stream);
}

/// Human-readable device name, or `None` if the backend cannot describe the device.
fn device_name(device: &cpal::Device) -> Option<String> {
    device
        .description()
        .ok()
        .map(|d| d.name().to_string())
        .filter(|n| !n.is_empty())
}

/// Turn a cpal error into something a user can act on.
///
/// The generic message ("a backend error occurred") tells nobody what to do. These four kinds
/// have specific fixes, and the onboarding microphone step shows the text verbatim.
fn describe(error: &cpal::Error) -> String {
    match error.kind() {
        cpal::ErrorKind::PermissionDenied => "Windows is blocking microphone access. Open \
             Settings > Privacy & security > Microphone and turn on \"Let desktop apps access \
             your microphone\"."
            .to_string(),
        cpal::ErrorKind::DeviceBusy => {
            "another application is holding the microphone exclusively — close it and retry"
                .to_string()
        }
        cpal::ErrorKind::DeviceNotAvailable => {
            "the microphone is not available — it may have been unplugged".to_string()
        }
        cpal::ErrorKind::HostUnavailable => {
            "the Windows audio service is not responding — a reboot usually clears this".to_string()
        }
        _ => error.to_string(),
    }
}

fn open_stream(
    shared: &Arc<Shared>,
    device_name_arg: Option<String>,
) -> Result<cpal::Stream, String> {
    let host = cpal::default_host();
    let device = match &device_name_arg {
        Some(name) => host
            .input_devices()
            .map_err(|e| format!("cannot list input devices: {}", describe(&e)))?
            .find(|d| device_name(d).as_deref() == Some(name.as_str()))
            .ok_or_else(|| format!("input device not found: {name}"))?,
        None => host
            .default_input_device()
            .ok_or_else(|| "no input device — check that a microphone is connected".to_string())?,
    };

    let config = device
        .default_input_config()
        .map_err(|e| format!("cannot read the input format: {}", describe(&e)))?;
    let sample_rate = config.sample_rate();
    let channels = config.channels();
    let format = config.sample_format();
    let stream_config = config.config();

    let on_error = {
        let shared = Arc::clone(shared);
        move |e: cpal::Error| {
            *shared.error.lock().unwrap() =
                Some(format!("the microphone stopped: {}", describe(&e)));
        }
    };

    // One closure body per sample format. WASAPI usually gives f32; integer formats appear on
    // some drivers and in exclusive mode. Only one match arm runs, so each may move the config
    // and the error callback.
    macro_rules! build {
        ($sample:ty, $to_f32:expr) => {{
            let shared = Arc::clone(shared);
            device.build_input_stream(
                stream_config,
                move |data: &[$sample], _: &cpal::InputCallbackInfo| {
                    let converted: Vec<f32> = data.iter().copied().map($to_f32).collect();
                    ingest(&shared, &converted, sample_rate, channels);
                },
                on_error,
                None,
            )
        }};
    }

    let stream = match format {
        cpal::SampleFormat::F32 => build!(f32, |s| s),
        cpal::SampleFormat::I16 => build!(i16, |s| s as f32 / 32768.0),
        cpal::SampleFormat::U16 => build!(u16, |s| (s as f32 - 32768.0) / 32768.0),
        cpal::SampleFormat::I32 => build!(i32, |s| s as f32 / 2147483648.0),
        cpal::SampleFormat::I8 => build!(i8, |s| s as f32 / 128.0),
        cpal::SampleFormat::U8 => build!(u8, |s| (s as f32 - 128.0) / 128.0),
        other => return Err(format!("unsupported sample format: {other:?}")),
    };
    stream.map_err(|e| format!("cannot open the microphone: {}", describe(&e)))
}

/// Append one captured buffer and update the meter.
fn ingest(shared: &Arc<Shared>, samples: &[f32], sample_rate: u32, channels: u16) {
    if let Ok(mut buffer) = shared.buffer.lock() {
        buffer.append(samples, sample_rate, channels);
    }
    if let Ok(mut level) = shared.level.lock() {
        *level = smooth_level(*level, level_from_rms(rms(samples)));
    }
}

/// `--record-test <seconds> <path>`: record from the default microphone and write a WAV.
///
/// The macOS binary has the same flag. It proves the whole capture path end to end — device
/// open, format conversion, resample, encode — without needing the UI or a model.
pub fn record_test(seconds: f64, path: &str) -> i32 {
    let mut recorder = Recorder::new();
    match Recorder::input_devices() {
        Ok(names) => println!(
            "using input device: {}",
            names.first().map(String::as_str).unwrap_or("default")
        ),
        Err(e) => eprintln!("warning: {e}"),
    }
    if let Err(e) = recorder.start(None) {
        eprintln!("FAIL cannot start recording: {e}");
        return 1;
    }
    println!("recording {seconds}s — speak now");
    // Draw the same level the onboarding meter uses. On a machine where the device opens but
    // hears nothing, this shows it while recording instead of after.
    let started = std::time::Instant::now();
    while started.elapsed().as_secs_f64() < seconds {
        std::thread::sleep(std::time::Duration::from_millis(250));
        let bars = (recorder.level() * 20.0).round() as usize;
        println!(
            "  {:5.2}s [{:<20}]",
            recorder.buffered_seconds(),
            "#".repeat(bars.min(20))
        );
    }
    let samples = recorder.stop();

    if let Some(e) = recorder.error() {
        eprintln!("FAIL {e}");
        return 1;
    }
    if samples.is_empty() {
        eprintln!("FAIL captured no samples — the device opened but delivered nothing");
        return 1;
    }
    let wav = openwispr_core::wav::encode(&samples, openwispr_core::wav::SAMPLE_RATE);
    if let Err(e) = std::fs::write(path, &wav) {
        eprintln!("FAIL cannot write {path}: {e}");
        return 1;
    }
    let duration = samples.len() as f64 / openwispr_core::wav::SAMPLE_RATE as f64;
    let peak = samples.iter().fold(0.0_f32, |m, s| m.max(s.abs()));
    println!(
        "wrote {path}: {} samples, {duration:.2}s, {} bytes, peak {peak:.3}, rms {:.4}",
        samples.len(),
        wav.len(),
        rms(&samples)
    );
    if peak < 0.0001 {
        println!("WARNING the recording is silent — check that the microphone is not muted");
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fresh_recorder_is_idle() {
        let r = Recorder::new();
        assert!(!r.is_recording());
        assert_eq!(r.level(), 0.0);
        assert_eq!(r.buffered_seconds(), 0.0);
        assert!(r.error().is_none());
    }

    #[test]
    fn stopping_an_idle_recorder_returns_nothing() {
        let mut r = Recorder::new();
        assert!(r.stop().is_empty());
    }

    #[test]
    fn an_unknown_device_name_is_reported_not_swallowed() {
        let mut r = Recorder::new();
        let err = r
            .start(Some("no such microphone".into()))
            .expect_err("should fail");
        assert!(err.contains("no such microphone"), "got: {err}");
        assert!(!r.is_recording(), "a failed start must leave it idle");
    }

    #[test]
    fn ingest_fills_the_buffer_and_moves_the_meter() {
        let shared = Arc::new(Shared::default());
        // half a second of 48 kHz stereo at half amplitude
        ingest(&shared, &vec![0.5; 48_000], 48_000, 2);
        let seconds = shared.buffer.lock().unwrap().buffered_seconds();
        assert!((seconds - 0.5).abs() < 0.01, "got {seconds} s");
        assert!(*shared.level.lock().unwrap() > 0.0);
    }

    // Enumeration talks to the real audio host, so it must not panic on a machine with no
    // input device (a CI runner, for instance) — it returns a list or an error.
    #[test]
    fn listing_devices_does_not_panic() {
        let _ = Recorder::input_devices();
    }
}
