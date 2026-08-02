//! The dictation loop: hold the trigger, speak, release, get text at the cursor.
//!
//! Mirrors `AppController.stopDictation` on macOS. Pipeline order is the same on both
//! platforms and is enforced by `openwispr_core::pipeline`:
//! raw transcript → dictionary → cleanup → snippets → paste.

use crate::audio::Recorder;
use crate::paste::{self, Delivery};
use crate::trigger::{Action, CancelReason, Trigger};
use crate::{hook, models};
use openwispr_core::{dictionary::DictionaryData, text};
use std::path::PathBuf;

/// Outcome of one hold-speak-release cycle, so callers can report it without re-deriving it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Delivered {
        text: String,
        delivery: Delivery,
        /// Set when auto-paste was wanted but refused, e.g. an elevated target window.
        note: Option<String>,
    },
    /// Nothing was said, or Whisper heard nothing.
    Empty,
    /// Dictation is switched off for the focused application.
    SkippedApp(String),
    Cancelled(CancelReason),
    Failed(String),
}

pub struct Settings {
    pub model_path: PathBuf,
    pub auto_paste: bool,
    pub remove_fillers: bool,
    pub clean_up: bool,
    pub dictionary: DictionaryData,
    pub snippets: Vec<openwispr_core::snippets::Snippet>,
    /// Executable names where dictation stays silent, e.g. "keepass.exe".
    pub disabled_apps: Vec<String>,
}

impl Settings {
    /// Defaults for a fresh install: whatever the hardware probe recommends, auto-paste on.
    pub fn with_recommended_model() -> Self {
        let model = models::by_id(crate::hardware::probe().recommend())
            .expect("recommend() names a catalogue model");
        Self {
            model_path: models::path_of(model),
            auto_paste: true,
            remove_fillers: true,
            clean_up: true,
            dictionary: DictionaryData::default(),
            snippets: Vec::new(),
            disabled_apps: Vec::new(),
        }
    }
}

/// Is this word ordinary English?
///
/// The dictionary's fuzzy correction needs this oracle, or a vocabulary entry rewrites the
/// real word that merely sounds like it ("not" became "notes" — see the macOS regression in
/// `core/fixtures/dictionary.json`).
///
/// Windows has `ISpellChecker` for this and it is not wired up yet, so this answers "no" for
/// everything. That is safe only while the vocabulary is empty, which it is until the
/// dictionary editor ships: `dictionary::apply` returns before consulting the oracle when
/// `vocab` is empty. Wiring `ISpellChecker` is a prerequisite for shipping that editor.
fn is_real_word(_word: &str) -> bool {
    false
}

pub struct Session {
    recorder: Recorder,
    settings: Settings,
    /// Remembered at Start so a window change mid-dictation cannot redirect the text.
    target_exe: Option<String>,
}

impl Session {
    pub fn new(settings: Settings) -> Self {
        Self {
            recorder: Recorder::new(),
            settings,
            target_exe: None,
        }
    }

    /// Handle one action from the keyboard hook. Returns an outcome when a cycle completed.
    pub fn handle(&mut self, action: Action) -> Option<Outcome> {
        match action {
            Action::Start => {
                // Read the focused app once, here. Checking at release instead would let a
                // window switch during the hold decide where the text goes.
                self.target_exe = paste::foreground_exe();
                if let Some(exe) = &self.target_exe {
                    if paste::is_disabled_for(Some(exe), &self.settings.disabled_apps) {
                        return Some(Outcome::SkippedApp(exe.clone()));
                    }
                }
                match self.recorder.start(None) {
                    Ok(()) => None,
                    Err(e) => Some(Outcome::Failed(e)),
                }
            }
            Action::Stop { .. } => {
                let samples = self.recorder.stop();
                if let Some(e) = self.recorder.error() {
                    return Some(Outcome::Failed(e));
                }
                if samples.is_empty() {
                    return Some(Outcome::Empty);
                }
                Some(self.finish(&samples))
            }
            Action::Cancel(reason) => {
                // Stop the device but throw the audio away.
                let _ = self.recorder.stop();
                Some(Outcome::Cancelled(reason))
            }
            Action::Nothing => None,
        }
    }

    fn finish(&mut self, samples: &[f32]) -> Outcome {
        let raw = match transcribe(&self.settings, samples) {
            Ok(text) => text,
            Err(e) => return Outcome::Failed(e),
        };
        let cleaned = openwispr_core::pipeline(
            &raw,
            &self.settings.dictionary,
            text::Options {
                remove_fillers: self.settings.remove_fillers,
                clean_up: self.settings.clean_up,
            },
            &self.settings.snippets,
            &is_real_word,
        );
        if cleaned.trim().is_empty() {
            return Outcome::Empty;
        }
        let (delivery, note) = paste::paste(&cleaned, self.settings.auto_paste);
        Outcome::Delivered {
            text: cleaned,
            delivery,
            note,
        }
    }
}

#[cfg(feature = "asr")]
fn transcribe(settings: &Settings, samples: &[f32]) -> Result<String, String> {
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get().min(8)) as i32;
    // English-only weights must be told "en"; the multilingual turbo model auto-detects.
    let language = if settings.model_path.to_string_lossy().contains(".en.") {
        Some("en")
    } else {
        None
    };
    crate::asr::transcribe(&settings.model_path, samples, language, false, threads)
}

#[cfg(not(feature = "asr"))]
fn transcribe(_settings: &Settings, _samples: &[f32]) -> Result<String, String> {
    Err("this build has no transcription: rebuild with --features asr".into())
}

/// `--dictate`: run the loop headlessly, printing every cycle.
///
/// This exists so hold-to-talk can be tested on Windows before any of the UI is built. It is
/// also the manual gate CI cannot cover: no runner has an interactive desktop, so no runner
/// can press a key or own the foreground window.
pub fn run_headless(trigger: Trigger) -> i32 {
    let settings = Settings::with_recommended_model();
    if !settings.model_path.exists() {
        eprintln!(
            "no model at {}\nrun: openwispr.exe --download-model {}",
            settings.model_path.display(),
            crate::hardware::probe().recommend()
        );
        return 1;
    }
    let actions = match hook::install(trigger) {
        Ok(rx) => rx,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };
    println!(
        "OpenWispr is listening. Hold {} and speak; release to paste. Escape cancels. Ctrl+C quits.",
        trigger.label()
    );
    if let Some(warning) = trigger.warning() {
        println!("note: {warning}");
    }

    let mut session = Session::new(settings);
    for action in actions {
        if action == Action::Start {
            println!("listening…");
        }
        match session.handle(action) {
            Some(Outcome::Delivered {
                text,
                delivery,
                note,
            }) => {
                let where_ = match delivery {
                    Delivery::Pasted => "pasted",
                    Delivery::Copied => "copied to the clipboard",
                };
                println!("{where_}: {text}");
                if let Some(note) = note {
                    println!("  note: {note}");
                }
            }
            Some(Outcome::Empty) => println!("nothing heard"),
            Some(Outcome::SkippedApp(exe)) => println!("dictation is off for {exe}"),
            Some(Outcome::Cancelled(CancelReason::TooShort)) => println!("too short — ignored"),
            Some(Outcome::Cancelled(CancelReason::Escaped)) => println!("cancelled"),
            Some(Outcome::Failed(e)) => eprintln!("failed: {e}"),
            None => {}
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use openwispr_core::snippets::Snippet;

    fn settings() -> Settings {
        Settings {
            model_path: PathBuf::from("/nonexistent/ggml-tiny.en.bin"),
            auto_paste: true,
            remove_fillers: true,
            clean_up: true,
            dictionary: DictionaryData::default(),
            snippets: vec![Snippet {
                triggers: vec!["my email".into()],
                to: "ck@example.com".into(),
            }],
            disabled_apps: vec!["keepass.exe".to_string()],
        }
    }

    #[test]
    fn a_disabled_app_stops_the_dictation_before_the_microphone_opens() {
        let mut session = Session::new(settings());
        session.target_exe = Some("keepass.exe".into());
        // Reaching straight into the check, because the foreground window cannot be faked
        // on the dev box. Start would call foreground_exe(), which is None here.
        assert!(paste::is_disabled_for(
            session.target_exe.as_deref(),
            &session.settings.disabled_apps
        ));
    }

    #[test]
    fn nothing_recorded_reports_empty_rather_than_transcribing() {
        let mut session = Session::new(settings());
        // The recorder never started, so stop() yields no samples.
        assert_eq!(
            session.handle(Action::Stop { held_ms: 900 }),
            Some(Outcome::Empty)
        );
    }

    #[test]
    fn a_cancel_is_reported_and_discards_audio() {
        let mut session = Session::new(settings());
        assert_eq!(
            session.handle(Action::Cancel(CancelReason::TooShort)),
            Some(Outcome::Cancelled(CancelReason::TooShort))
        );
        assert_eq!(
            session.handle(Action::Cancel(CancelReason::Escaped)),
            Some(Outcome::Cancelled(CancelReason::Escaped))
        );
    }

    #[test]
    fn nothing_produces_no_outcome() {
        let mut session = Session::new(settings());
        assert_eq!(session.handle(Action::Nothing), None);
    }

    #[test]
    fn the_real_word_oracle_is_inert_and_the_vocabulary_is_empty() {
        // Paired on purpose: answering "no" to everything is only safe while vocab is empty,
        // because dictionary::apply returns before consulting the oracle in that case. If a
        // future change ships a default vocabulary, this test fails and ISpellChecker is due.
        assert!(!is_real_word("not"));
        assert!(settings().dictionary.vocab.is_empty());
    }

    #[cfg(not(feature = "asr"))]
    #[test]
    fn a_build_without_asr_says_so_instead_of_pretending() {
        let err = transcribe(&settings(), &[0.1; 16_000]).unwrap_err();
        assert!(err.contains("--features asr"), "{err}");
    }
}
