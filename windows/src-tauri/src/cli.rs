//! Headless command-line flags, mirroring the macOS binary's `--selftest` family.
//!
//! `run` returns `Some(exit_code)` when it handled a flag, `None` to continue into the GUI.

#[cfg(feature = "asr")]
use crate::asr;
use crate::{audio, dictation, hardware, models, selftest, trigger};

pub fn run(args: &[String]) -> Option<i32> {
    let flag = args.first()?;
    match flag.as_str() {
        "--selftest" => {
            attach_console();
            Some(selftest::run())
        }
        // Mirrors the macOS binary: --record-test 3 out.wav
        "--record-test" => {
            attach_console();
            let seconds = args
                .get(1)
                .and_then(|s| s.parse::<f64>().ok())
                .unwrap_or(3.0);
            match args.get(2) {
                Some(path) => Some(audio::record_test(seconds, path)),
                None => {
                    eprintln!("--record-test needs a duration and an output path\n\n{USAGE}");
                    Some(2)
                }
            }
        }
        "--devices" => {
            attach_console();
            match audio::Recorder::input_devices() {
                Ok(names) if names.is_empty() => {
                    println!("no input devices found");
                    Some(1)
                }
                Ok(names) => {
                    println!("input devices (default first):");
                    for name in names {
                        println!("  {name}");
                    }
                    Some(0)
                }
                Err(e) => {
                    eprintln!("{e}");
                    Some(1)
                }
            }
        }
        "--version" | "-v" => {
            attach_console();
            println!("OpenWispr {}", env!("CARGO_PKG_VERSION"));
            Some(0)
        }
        "--help" | "-h" => {
            attach_console();
            println!("{USAGE}");
            Some(0)
        }
        // Mirrors the macOS binary: --transcribe-file speech.wav [ggml-model.bin]
        "--transcribe-file" => {
            attach_console();
            match args.get(1) {
                Some(wav) => Some(transcribe_file(wav, args.get(2).map(String::as_str))),
                None => {
                    eprintln!("--transcribe-file needs a 16 kHz WAV path\n\n{USAGE}");
                    Some(2)
                }
            }
        }
        // No id: print the catalogue instead of guessing which model the user wanted.
        "--download-model" => {
            attach_console();
            Some(download_model(args.get(1).map(String::as_str)))
        }
        // Hold-to-talk without any UI. This is how the hook, the paste path and per-app
        // disable get verified on real hardware: no CI runner has an interactive desktop.
        "--dictate" => {
            attach_console();
            let trigger = match args.get(1) {
                Some(id) => match trigger::Trigger::from_id(id) {
                    Some(t) => t,
                    None => {
                        eprintln!(
                            "unknown trigger: {id}\ntry right-ctrl, right-alt, caps-lock, or key-<hex>"
                        );
                        return Some(2);
                    }
                },
                None => trigger::Trigger::RightCtrl,
            };
            Some(dictation::run_headless(trigger))
        }
        "--hardware" => {
            attach_console();
            let hw = hardware::probe();
            println!("{}", hw.verdict());
            let model = models::by_id(hw.recommend()).expect("recommend() names a catalogue model");
            println!(
                "recommended: {} — {} MB download, ~{} MB RAM\n{}",
                model.file,
                model.bytes / 1_000_000,
                model.ram_mb,
                models::path_of(model).display()
            );
            Some(0)
        }
        other if other.starts_with('-') => {
            attach_console();
            eprintln!("unknown flag: {other}\n\n{USAGE}");
            Some(2)
        }
        // Not a flag: let the GUI start (Windows passes stray arguments on file-association launches).
        _ => None,
    }
}

const USAGE: &str = "\
OpenWispr — local-first voice dictation.

Run with no arguments to start the app. Headless flags:

  --selftest                       run the built-in checks, print PASS/FAIL per check
  --record-test <secs> <out.wav>   record from the default microphone to a 16 kHz mono WAV
  --devices                        list the input devices this machine offers
  --transcribe-file <wav> [model]  transcribe a 16 kHz mono WAV and print the text
  --download-model [id]            download a whisper model (no id lists them)
  --hardware                       print what this PC can run and which model to use
  --dictate [trigger]              hold-to-talk with no window (default right-ctrl)
  --version                        print the version
  --help                           print this message";

fn download_model(id: Option<&str>) -> i32 {
    let Some(id) = id else {
        println!("models (pass an id to --download-model):");
        for model in &models::MODELS {
            println!("  {:<20} {}", model.id, model.label);
        }
        return 0;
    };
    let Some(model) = models::by_id(id) else {
        eprintln!("unknown model: {id}\n\n{USAGE}");
        return 2;
    };
    let mut shown = u64::MAX;
    let result = models::ensure(model, &mut |done, total| {
        let pct = done * 100 / total.max(1);
        if pct != shown {
            shown = pct;
            println!("{pct}% ({done}/{total} bytes)");
        }
    });
    match result {
        Ok(path) => {
            println!("{}", path.display());
            0
        }
        Err(e) => {
            eprintln!("{e}");
            1
        }
    }
}

#[cfg(feature = "asr")]
fn transcribe_file(wav: &str, model: Option<&str>) -> i32 {
    use openwispr_core::wav;
    use std::path::PathBuf;

    let bytes = match std::fs::read(wav) {
        Ok(bytes) => bytes,
        Err(e) => {
            eprintln!("{wav}: {e}");
            return 1;
        }
    };
    // Both checks below read fixed offsets, so the layout has to be the one we write.
    if !wav::is_canonical(&bytes) {
        eprintln!(
            "{wav}: not a plain 44-byte-header WAV (extra chunks before the samples). \
             Re-encode it: afconvert -f WAVE -d LEI16@16000 -c 1 in.wav out.wav"
        );
        return 1;
    }
    // whisper.cpp only takes 16 kHz mono; decoding a 44.1 kHz file would transcribe noise.
    match wav::sample_rate_of(&bytes) {
        Some(wav::SAMPLE_RATE) => {}
        other => {
            eprintln!(
                "{wav}: need a {} Hz mono WAV, header says {other:?}",
                wav::SAMPLE_RATE
            );
            return 1;
        }
    }
    let samples = wav::decode(&bytes);

    let model_path = match model {
        Some(path) => PathBuf::from(path),
        None => match std::env::var_os("OPENWISPR_MODEL") {
            Some(path) => PathBuf::from(path),
            None => models::path_of(
                models::by_id(hardware::probe().recommend())
                    .expect("recommend() names a catalogue model"),
            ),
        },
    };
    // English-only weights must be told "en"; the multilingual turbo model auto-detects.
    let language = if model_path.to_string_lossy().contains(".en.") {
        Some("en")
    } else {
        None
    };
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get().min(8)) as i32;
    match asr::transcribe(&model_path, &samples, language, false, threads) {
        Ok(text) if text.trim().is_empty() => {
            eprintln!("no speech recognised in {wav}");
            1
        }
        Ok(text) => {
            println!("{text}");
            0
        }
        Err(e) => {
            eprintln!("{e}");
            1
        }
    }
}

#[cfg(not(feature = "asr"))]
fn transcribe_file(_wav: &str, _model: Option<&str>) -> i32 {
    eprintln!("this build has no transcription: rebuild with --features asr");
    3
}

/// Reattach stdout/stderr to the console that launched us.
///
/// A GUI subsystem binary starts with no console, so `println!` silently goes nowhere.
/// Without this, CI would assert against empty output and pass by accident.
#[cfg(windows)]
fn attach_console() {
    use windows::Win32::System::Console::{AttachConsole, ATTACH_PARENT_PROCESS};
    // Fails when there is no parent console (double-clicked). Nothing to print to, so ignore.
    let _ = unsafe { AttachConsole(ATTACH_PARENT_PROCESS) };
}

#[cfg(not(windows))]
fn attach_console() {}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn no_arguments_starts_the_gui() {
        assert_eq!(run(&[]), None);
    }

    #[test]
    fn a_stray_path_starts_the_gui() {
        assert_eq!(run(&args(&["C:\\note.txt"])), None);
    }

    #[test]
    fn unknown_flags_exit_two() {
        assert_eq!(run(&args(&["--wat"])), Some(2));
    }

    #[test]
    fn version_and_help_exit_zero() {
        assert_eq!(run(&args(&["--version"])), Some(0));
        assert_eq!(run(&args(&["--help"])), Some(0));
    }

    #[test]
    fn transcribe_file_without_a_path_exits_two() {
        assert_eq!(run(&args(&["--transcribe-file"])), Some(2));
    }

    #[test]
    fn download_model_rejects_an_unknown_id() {
        assert_eq!(run(&args(&["--download-model", "medium.en"])), Some(2));
    }

    #[test]
    fn listing_models_needs_no_network() {
        assert_eq!(run(&args(&["--download-model"])), Some(0));
    }
}
