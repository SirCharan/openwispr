//! Logic shared by the macOS and Windows builds of OpenWispr.
//!
//! Nothing in this crate may touch a platform API. Audio capture, hotkeys, paste and
//! transcription live in the platform binaries; this crate holds only the parts that
//! must produce identical output on both. Parity is enforced by `fixtures/` — the same
//! JSON tables drive these tests and the Swift `--selftest`.
//!
//! Pipeline order, matching `AppController.stopDictation`:
//! raw transcript → [`dictionary::apply`] → [`text::process`] → [`snippets::apply`] → paste.

pub mod dictionary;
pub mod fixtures;
pub mod history;
pub mod snippets;
pub mod stats;
pub mod text;

/// Run the transcript through the full pipeline in the order both platforms use.
pub fn pipeline(
    raw: &str,
    dict: &dictionary::DictionaryData,
    options: text::Options,
    snips: &[dictionary::Replacement],
    is_real_word: dictionary::IsRealWord,
) -> String {
    let after_dict = dictionary::apply(raw, dict, is_real_word);
    let cleaned = text::process(&after_dict, options);
    snippets::apply(&cleaned, snips)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pipeline_runs_in_order() {
        // The dictionary fires before cleanup, so a replacement's casing survives; snippets
        // fire last, so an expansion is never re-capitalized by the cleanup pass.
        let dict = dictionary::DictionaryData {
            vocab: vec!["Kubernetes".into()],
            replacements: vec![dictionary::Replacement {
                from: "gonna".into(),
                to: "going to".into(),
            }],
        };
        let snips = vec![dictionary::Replacement {
            from: "my email".into(),
            to: "ck@example.com".into(),
        }];
        let is_real = |w: &str| ["going", "to", "deploy", "on", "send", "my", "email"].contains(&w);

        let got = pipeline(
            "um i'm gonna deploy on kubernetis . send my email",
            &dict,
            text::Options {
                remove_fillers: true,
                clean_up: true,
            },
            &snips,
            &is_real,
        );
        assert_eq!(
            got,
            "I'm going to deploy on Kubernetes. Send ck@example.com"
        );
    }
}
