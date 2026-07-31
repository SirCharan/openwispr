//! Voice shortcuts: a spoken trigger phrase expands to canned text (email, address, boilerplate).
//!
//! Reuses `Replacement` (from = trigger, to = expansion). Applied after cleanup so expansions
//! keep their exact casing. Ported from `Snippets.swift`.

use crate::dictionary::Replacement;
use regex::RegexBuilder;

pub fn apply(text: &str, snippets: &[Replacement]) -> String {
    let mut s = text.to_string();
    for snip in snippets.iter().filter(|s| !s.from.is_empty()) {
        let pattern = format!(r"\b{}\b", regex::escape(&snip.from));
        if let Ok(re) = RegexBuilder::new(&pattern).case_insensitive(true).build() {
            s = re.replace_all(&s, snip.to.as_str()).into_owned();
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct SnippetFixtures {
        cases: Vec<Case>,
    }

    #[derive(Deserialize)]
    struct Case {
        snippets: Vec<Replacement>,
        input: String,
        expected: String,
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
}
