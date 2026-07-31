//! Cleanup applied to a raw transcript before it is pasted.
//!
//! Whisper already punctuates, so the value added here is filler removal plus
//! capitalization and spacing normalization. Ported from `TextProcessor.swift`;
//! `fixtures/text.json` holds the cases both platforms must agree on.

#[derive(Debug, Clone, Copy)]
pub struct Options {
    pub remove_fillers: bool,
    /// Capitalize sentences, collapse whitespace, fix standalone "i".
    pub clean_up: bool,
}

const FILLERS: &[&str] = &["um", "umm", "uh", "uhh", "er", "erm", "hmm", "mmm", "uhm"];

pub fn process(text: &str, options: Options) -> String {
    let mut out = text.to_string();
    if options.remove_fillers {
        out = remove_fillers(&out);
    }
    if options.clean_up {
        out = clean_up(&out);
    }
    out.trim().to_string()
}

fn remove_fillers(text: &str) -> String {
    text.split(' ')
        .filter(|word| !word.is_empty())
        .filter(|word| {
            let bare = word
                .to_lowercase()
                .trim_matches(|c| ".,!?;:".contains(c))
                .to_string();
            !FILLERS.contains(&bare.as_str())
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn clean_up(text: &str) -> String {
    let s = collapse_whitespace(text);
    let s = drop_space_before_punctuation(&s);
    let s = fix_standalone_i(&s);
    capitalize_sentences(&s)
}

/// Collapse runs of whitespace into one space (Swift: `\s+` → " ").
fn collapse_whitespace(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_space = false;
    for ch in text.chars() {
        if ch.is_whitespace() {
            if !in_space {
                out.push(' ');
            }
            in_space = true;
        } else {
            out.push(ch);
            in_space = false;
        }
    }
    out
}

/// Drop a space that sits before punctuation (Swift: `\s+([.,!?;:])` → "$1").
fn drop_space_before_punctuation(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        if ".,!?;:".contains(ch) {
            while out.ends_with(' ') {
                out.pop();
            }
        }
        out.push(ch);
    }
    out
}

/// Uppercase the standalone pronoun "i" (Swift: `\bi\b` → "I").
fn fix_standalone_i(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    for (i, &ch) in chars.iter().enumerate() {
        if ch == 'i' {
            let before_is_word = i > 0 && is_word_char(chars[i - 1]);
            let after_is_word = i + 1 < chars.len() && is_word_char(chars[i + 1]);
            if !before_is_word && !after_is_word {
                out.push('I');
                continue;
            }
        }
        out.push(ch);
    }
    out
}

/// Word character as ICU's `\b` treats it: letters, digits, underscore.
fn is_word_char(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_'
}

/// Capitalize the first letter, and the first letter after `.`, `!` or `?`.
fn capitalize_sentences(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut capitalize_next = true;
    for ch in text.chars() {
        if capitalize_next && ch.is_alphabetic() {
            out.extend(ch.to_uppercase());
            capitalize_next = false;
        } else {
            out.push(ch);
            if ch == '.' || ch == '!' || ch == '?' {
                capitalize_next = true;
            }
        }
    }
    out
}

/// Collapse a Whisper hallucination loop: the same word 3 or more times in a row becomes one.
/// A deliberate double ("no no") is preserved. Used on meeting chunks only.
pub fn collapse_repeats(text: &str) -> String {
    let words: Vec<&str> = text.split(' ').filter(|w| !w.is_empty()).collect();
    let mut out: Vec<&str> = Vec::with_capacity(words.len());
    let mut i = 0;
    while i < words.len() {
        let mut j = i;
        while j < words.len() && words[j].to_lowercase() == words[i].to_lowercase() {
            j += 1;
        }
        if j - i >= 3 {
            out.push(words[i]);
        } else {
            out.extend_from_slice(&words[i..j]);
        }
        i = j;
    }
    out.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct TextFixtures {
        process: Vec<ProcessCase>,
        collapse_repeats: Vec<RepeatCase>,
    }

    #[derive(Deserialize)]
    struct ProcessCase {
        input: String,
        remove_fillers: bool,
        clean_up: bool,
        expected: String,
    }

    #[derive(Deserialize)]
    struct RepeatCase {
        input: String,
        expected: String,
    }

    #[test]
    fn matches_the_shared_fixtures() {
        let f: TextFixtures = fixtures::load("text.json");
        assert!(!f.process.is_empty(), "fixture file is empty");
        for case in &f.process {
            let got = process(
                &case.input,
                Options {
                    remove_fillers: case.remove_fillers,
                    clean_up: case.clean_up,
                },
            );
            assert_eq!(got, case.expected, "process({:?})", case.input);
        }
        for case in &f.collapse_repeats {
            assert_eq!(
                collapse_repeats(&case.input),
                case.expected,
                "collapse_repeats({:?})",
                case.input
            );
        }
    }
}
