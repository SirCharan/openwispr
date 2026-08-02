//! Voice shortcuts: a spoken trigger phrase expands to canned text (email, address, boilerplate).
//!
//! Applied after cleanup so expansions keep their exact casing. A snippet carries several
//! triggers because Whisper writes the same phrase several ways ("add my linkedin",
//! "add my linked in"). Ported from `Snippets.swift`; both are held to `fixtures/snippets.json`.
//!
//! Expansion is a two-step pass so an LLM rewrite cannot mangle an email address or URL:
//! [`expand`] swaps each expansion for a sentinel, the caller rewrites around the sentinels,
//! and [`restore`] puts the expansions back.

use regex::RegexBuilder;
use serde::{Deserialize, Serialize};
use std::cmp::Reverse;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Snippet {
    /// Spoken forms that expand to `to`. Any of them fires.
    #[serde(default)]
    pub triggers: Vec<String>,
    #[serde(default)]
    pub to: String,
}

/// A private-use codepoint: it survives a rewrite better than punctuation an LLM would tidy,
/// and it is not a word character, so `\b` still matches around it.
fn token(n: usize) -> String {
    format!("\u{E000}{n}\u{E000}")
}

/// Expansions swapped for sentinels, plus the table that puts them back.
pub struct Expansion {
    pub protected: String,
    /// Sentinel to expansion, in the order the sentinels were assigned.
    pub tokens: Vec<(String, String)>,
}

impl Expansion {
    /// The transcript with every expansion in place. Restoring its own sentinels cannot fail.
    pub fn expanded(&self) -> String {
        restore(&self.protected, &self.tokens).expect("expand always leaves its own sentinels")
    }
}

pub fn expand(text: &str, snippets: &[Snippet]) -> Expansion {
    // Longest trigger first, so "add my email signature" beats "add my email" wherever both
    // could match. `sort_by_key` is stable, so equal-length triggers keep the user's row order.
    let mut pairs: Vec<(&str, &str)> = snippets
        .iter()
        .filter(|s| !s.to.is_empty()) // a preset the user has not filled in yet is inert
        .flat_map(|s| {
            s.triggers
                .iter()
                .map(|t| t.trim())
                .filter(|t| !t.is_empty())
                .map(move |t| (t, s.to.as_str()))
        })
        .collect();
    pairs.sort_by_key(|(trigger, _)| Reverse(trigger.chars().count()));

    let mut protected = text.to_string();
    let mut tokens = Vec::new();
    for (trigger, to) in pairs {
        let pattern = format!(r"\b{}\b", regex::escape(trigger));
        let Ok(re) = RegexBuilder::new(&pattern).case_insensitive(true).build() else {
            continue;
        };
        if !re.is_match(&protected) {
            continue;
        }
        let tok = token(tokens.len());
        // The sentinel goes in, not the expansion: nothing already expanded is ever rescanned,
        // and `$` in an expansion stays literal instead of reading as a capture reference.
        protected = re.replace_all(&protected, tok.as_str()).into_owned();
        tokens.push((tok, to.to_string()));
    }
    Expansion { protected, tokens }
}

/// Puts the expansions back. `None` when a sentinel is missing — a rewrite dropped it, and the
/// caller should fall back to [`Expansion::expanded`] rather than paste a half-expanded line.
pub fn restore(text: &str, tokens: &[(String, String)]) -> Option<String> {
    let mut s = text.to_string();
    for (tok, to) in tokens {
        if !s.contains(tok.as_str()) {
            return None;
        }
        s = s.replace(tok.as_str(), to);
    }
    Some(s)
}

/// Expand with no rewrite in between.
pub fn apply(text: &str, snippets: &[Snippet]) -> String {
    expand(text, snippets).expanded()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct SnippetFixtures {
        cases: Vec<Case>,
        protect: Vec<ProtectCase>,
    }

    #[derive(Deserialize)]
    struct Case {
        snippets: Vec<Snippet>,
        input: String,
        expected: String,
    }

    #[derive(Deserialize)]
    struct ProtectCase {
        snippets: Vec<Snippet>,
        input: String,
        expanded: String,
        /// `{n}` stands for the nth sentinel.
        rewritten: String,
        expected: Option<String>,
    }

    #[test]
    fn matches_the_shared_fixtures() {
        let f: SnippetFixtures = fixtures::load("snippets.json");
        assert!(!f.cases.is_empty(), "fixture file is empty");
        for case in &f.cases {
            assert_eq!(
                apply(&case.input, &case.snippets),
                case.expected,
                "apply({:?})",
                case.input
            );
        }
    }

    #[test]
    fn survives_a_rewrite_between_expand_and_restore() {
        let f: SnippetFixtures = fixtures::load("snippets.json");
        assert!(!f.protect.is_empty(), "no protect cases");
        for case in &f.protect {
            let e = expand(&case.input, &case.snippets);
            assert_eq!(e.expanded(), case.expanded, "expanded({:?})", case.input);

            let mut rewritten = case.rewritten.clone();
            for (i, (tok, _)) in e.tokens.iter().enumerate() {
                rewritten = rewritten.replace(&format!("{{{i}}}"), tok);
            }
            assert_eq!(
                restore(&rewritten, &e.tokens),
                case.expected,
                "restore({:?})",
                case.rewritten
            );
        }
    }
}
