//! The user dictionary: exact phrase replacements, then fuzzy correction of near-miss
//! words toward the user's custom vocabulary.
//!
//! Ported from `Dictionary.swift`. Every threshold and guard here was tuned against real
//! dictation failures, so `fixtures/dictionary.json` pins the behaviour on both platforms.
//! The real-word oracle is injected rather than owned: macOS uses `NSSpellChecker`,
//! Windows uses `ISpellChecker`, and tests use a fixed word list.

use regex::RegexBuilder;
use serde::{Deserialize, Serialize};

/// Words of 6 or more characters.
pub const FUZZY_THRESHOLD: f64 = 0.86;
/// 3 to 5 characters: one edit is a large share of a short word.
pub const SHORT_WORD_THRESHOLD: f64 = 0.92;
/// Two spoken words merged into one vocabulary term.
pub const PHRASE_THRESHOLD: f64 = 0.92;

const TRIM: &[char] = &['.', ',', '!', '?', ';', ':', '"', '\'', '(', ')'];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Replacement {
    pub from: String,
    pub to: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DictionaryData {
    /// Preferred spellings, fuzzy-matched (for example "WhisperKit").
    #[serde(default)]
    pub vocab: Vec<String>,
    /// Exact phrase to replacement.
    #[serde(default)]
    pub replacements: Vec<Replacement>,
}

/// Answers "is this an ordinary English word?".
pub type IsRealWord<'a> = &'a dyn Fn(&str) -> bool;

pub fn apply(text: &str, d: &DictionaryData, is_real_word: IsRealWord) -> String {
    let mut s = text.to_string();

    // 1) exact phrase replacements, case-insensitive
    for r in d.replacements.iter().filter(|r| !r.from.is_empty()) {
        let pattern = format!(r"\b{}\b", regex::escape(&r.from));
        if let Ok(re) = RegexBuilder::new(&pattern).case_insensitive(true).build() {
            s = re.replace_all(&s, r.to.as_str()).into_owned();
        }
    }

    // 2) fuzzy-correct words toward the custom vocabulary
    if d.vocab.is_empty() {
        return s;
    }
    let words: Vec<&str> = s.split(' ').collect();
    let mut out: Vec<String> = Vec::with_capacity(words.len());
    let mut i = 0;
    while i < words.len() {
        // Prefer a two-word match, so "open whisper" beats correcting each half separately.
        if i + 1 < words.len() {
            if let Some(merged) = merged_match(words[i], words[i + 1], &d.vocab, is_real_word) {
                out.push(merged);
                i += 2;
                continue;
            }
        }
        out.push(correct_word(words[i], &d.vocab, is_real_word));
        i += 1;
    }
    out.join(" ")
}

fn correct_word(word: &str, vocab: &[String], is_real_word: IsRealWord) -> String {
    // preserve leading and trailing punctuation
    let core = word.trim_matches(|c| TRIM.contains(&c));
    if core.chars().count() < 3 {
        return word.to_string();
    }
    let lower = core.to_lowercase();

    // already correct (case-insensitive exact) → snap to the vocabulary's casing
    if let Some(exact) = vocab.iter().find(|v| v.to_lowercase() == lower) {
        return word.replace(core, exact);
    }

    // An ordinary English word is what the speaker meant. Never rewrite it.
    // Without this guard "not" becomes "notes" whenever "notes" is in the vocabulary
    // (Jaro-Winkler scores them 0.907), and every such rewrite corrupts a dictation.
    if is_real_word(&lower) {
        return word.to_string();
    }

    let mut best: Option<(&String, f64)> = None;
    for term in vocab {
        let score = similarity(&lower, &term.to_lowercase());
        if score > best.map_or(0.0, |(_, s)| s) {
            best = Some((term, score));
        }
    }
    if let Some((term, score)) = best {
        if score >= threshold_for_length(core.chars().count()) {
            return word.replace(core, term);
        }
    }
    word.to_string()
}

/// Two spoken words that together sound like one vocabulary term ("open whisper" → "OpenWispr").
///
/// The halves are deliberately NOT real-word-guarded: both "open" and "whisper" are ordinary
/// words, and guarding them would defeat the only case this exists for. Instead the *joined*
/// form must not be a real word ("not able" → "notable" is rejected here), the vocabulary term
/// must be long enough to be a proper noun, and the bar is raised to `PHRASE_THRESHOLD`.
fn merged_match(a: &str, b: &str, vocab: &[String], is_real_word: IsRealWord) -> Option<String> {
    let core_a = a.trim_matches(|c| TRIM.contains(&c));
    let core_b = b.trim_matches(|c| TRIM.contains(&c));
    if core_a.chars().count() < 2 || core_b.chars().count() < 2 {
        return None;
    }
    // a merge would swallow punctuation sitting between or before the pair
    if core_a != a || !b.starts_with(core_b) {
        return None;
    }
    let joined = format!("{core_a}{core_b}").to_lowercase();
    if is_real_word(&joined) {
        return None;
    }
    let joined_len = joined.chars().count() as i64;

    let mut best: Option<(&String, f64)> = None;
    for term in vocab.iter().filter(|t| t.chars().count() >= 6) {
        let flat = term.replace(' ', "").to_lowercase();
        // a merge should be about the same length as its target, not a term plus a stray word
        if (flat.chars().count() as i64 - joined_len).abs() > 3 {
            continue;
        }
        let score = similarity(&joined, &flat);
        if score > best.map_or(0.0, |(_, s)| s) {
            best = Some((term, score));
        }
    }

    // The merge must beat what the first word achieves alone, or "stratsea and" swallows "and":
    // the joined form still scores high because Jaro-Winkler rewards the shared prefix.
    let mut solo_best = 0.0_f64;
    let lower_a = core_a.to_lowercase();
    if !is_real_word(&lower_a) {
        for term in vocab {
            solo_best = solo_best.max(similarity(&lower_a, &term.to_lowercase()));
        }
    }

    let (term, score) = best?;
    if score < PHRASE_THRESHOLD || score <= solo_best {
        return None;
    }
    // keep trailing punctuation
    Some(format!("{}{}", term, &b[core_b.len()..]))
}

fn threshold_for_length(n: usize) -> f64 {
    if n >= 6 {
        FUZZY_THRESHOLD
    } else {
        SHORT_WORD_THRESHOLD
    }
}

/// Best of the spelled and the sounded match. Whisper mis-hears proper nouns phonetically,
/// so "stratsea" is only 0.868 against "Stratzy" by spelling but 1.0 by sound.
pub fn similarity(a: &str, b: &str) -> f64 {
    jaro_winkler(a, b).max(jaro_winkler(&phonetic_key(a), &phonetic_key(b)))
}

/// Reduces a word to roughly what it sounds like: drop vowels after the first, fold letters
/// that share a sound (c/q→k, z→s, d→t, b→p, v→f, g→k, x→ks), collapse doubles.
/// "stratsea" and "Stratzy" both reduce to "strts".
pub fn phonetic_key(s: &str) -> String {
    let mut w = s.to_lowercase();
    for (from, to) in [("ph", "f"), ("ck", "k"), ("qu", "kw")] {
        w = w.replace(from, to);
    }
    let mut folded = String::with_capacity(w.len());
    for (i, ch) in w.chars().enumerate() {
        if !ch.is_alphabetic() {
            continue;
        }
        if "aeiouy".contains(ch) {
            // a leading vowel still distinguishes the word
            if i == 0 {
                folded.push(ch);
            }
            continue;
        }
        match ch {
            'c' | 'q' | 'g' => folded.push('k'),
            'z' => folded.push('s'),
            'x' => folded.push_str("ks"),
            'v' => folded.push('f'),
            'd' => folded.push('t'),
            'b' => folded.push('p'),
            other => folded.push(other),
        }
    }
    let mut collapsed = String::with_capacity(folded.len());
    for ch in folded.chars() {
        if !collapsed.ends_with(ch) {
            collapsed.push(ch);
        }
    }
    collapsed
}

/// Is an edit from one word to another a spelling correction worth learning, or a content change?
/// Shared by the clipboard diff and the accessibility diff, which each used to carry their own
/// copy of a band that got this backwards.
pub fn is_spelling_fix(from: &str, to: &str, is_real_word: IsRealWord) -> bool {
    if from == to {
        return false;
    }
    let a = from.to_lowercase();
    let b = to.to_lowercase();
    if a == b {
        return true; // case-only fix: "delhi" → "Delhi"
    }
    if is_real_word(&b) {
        return false; // edited into ordinary English = content change
    }
    jaro_winkler(&a, &b) >= 0.70 // floor only; see the guard above
}

pub fn jaro_winkler(a: &str, b: &str) -> f64 {
    let j = jaro(a, b);
    let ca: Vec<char> = a.chars().collect();
    let cb: Vec<char> = b.chars().collect();
    // common prefix up to 4
    let mut prefix = 0;
    for i in 0..ca.len().min(cb.len()).min(4) {
        if ca[i] == cb[i] {
            prefix += 1;
        } else {
            break;
        }
    }
    j + prefix as f64 * 0.1 * (1.0 - j)
}

fn jaro(a: &str, b: &str) -> f64 {
    let s1: Vec<char> = a.chars().collect();
    let s2: Vec<char> = b.chars().collect();
    if s1.is_empty() && s2.is_empty() {
        return 1.0;
    }
    if s1.is_empty() || s2.is_empty() {
        return 0.0;
    }
    // Swift computes this with Int division, so short strings get a negative window and
    // therefore zero matches. Kept as isize so the two implementations agree.
    let match_distance = (s1.len().max(s2.len()) / 2) as isize - 1;
    let mut s1_matches = vec![false; s1.len()];
    let mut s2_matches = vec![false; s2.len()];
    let mut matches = 0usize;

    for i in 0..s1.len() {
        let start = (i as isize - match_distance).max(0);
        let end = (i as isize + match_distance + 1).min(s2.len() as isize);
        if start >= end {
            continue;
        }
        for k in start as usize..end as usize {
            if !s2_matches[k] && s1[i] == s2[k] {
                s1_matches[i] = true;
                s2_matches[k] = true;
                matches += 1;
                break;
            }
        }
    }
    if matches == 0 {
        return 0.0;
    }

    let mut t = 0.0;
    let mut k = 0usize;
    for i in 0..s1.len() {
        if !s1_matches[i] {
            continue;
        }
        while !s2_matches[k] {
            k += 1;
        }
        if s1[i] != s2[k] {
            t += 0.5;
        }
        k += 1;
    }

    let m = matches as f64;
    (m / s1.len() as f64 + m / s2.len() as f64 + (m - t) / m) / 3.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures;
    use std::collections::HashSet;

    #[derive(Deserialize)]
    struct DictFixtures {
        /// Stub English so the gate is deterministic and needs no system spell checker.
        english: Vec<String>,
        apply: Vec<ApplyCase>,
        jaro_winkler: Vec<ScoreCase>,
        phonetic_equal: Vec<[String; 2]>,
        phonetic_differ: Vec<[String; 2]>,
        spelling_fix: Vec<FixCase>,
    }

    #[derive(Deserialize)]
    struct ApplyCase {
        #[serde(default)]
        vocab: Vec<String>,
        #[serde(default)]
        replacements: Vec<Replacement>,
        input: String,
        expected: String,
    }

    #[derive(Deserialize)]
    struct ScoreCase {
        a: String,
        b: String,
        #[serde(default)]
        min: Option<f64>,
        #[serde(default)]
        max: Option<f64>,
    }

    #[derive(Deserialize)]
    struct FixCase {
        from: String,
        to: String,
        expected: bool,
    }

    #[test]
    fn matches_the_shared_fixtures() {
        let f: DictFixtures = fixtures::load("dictionary.json");
        let english: HashSet<String> = f.english.iter().map(|w| w.to_lowercase()).collect();
        let is_real = |w: &str| english.contains(&w.to_lowercase());

        assert!(!f.apply.is_empty(), "fixture file is empty");
        for case in &f.apply {
            let d = DictionaryData {
                vocab: case.vocab.clone(),
                replacements: case.replacements.clone(),
            };
            let got = apply(&case.input, &d, &is_real);
            assert_eq!(got, case.expected, "apply({:?})", case.input);
        }
        for case in &f.jaro_winkler {
            let score = jaro_winkler(&case.a, &case.b);
            if let Some(min) = case.min {
                assert!(
                    score > min,
                    "jw({}, {}) = {score}, want > {min}",
                    case.a,
                    case.b
                );
            }
            if let Some(max) = case.max {
                assert!(
                    score < max,
                    "jw({}, {}) = {score}, want < {max}",
                    case.a,
                    case.b
                );
            }
        }
        for [a, b] in &f.phonetic_equal {
            assert_eq!(
                phonetic_key(a),
                phonetic_key(b),
                "phonetic keys should match"
            );
        }
        for [a, b] in &f.phonetic_differ {
            assert_ne!(
                phonetic_key(a),
                phonetic_key(b),
                "phonetic keys should differ"
            );
        }
        for case in &f.spelling_fix {
            assert_eq!(
                is_spelling_fix(&case.from, &case.to, &is_real),
                case.expected,
                "is_spelling_fix({:?}, {:?})",
                case.from,
                case.to
            );
        }
    }
}
