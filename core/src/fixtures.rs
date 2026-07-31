//! Loader for the shared parity fixtures in `core/fixtures/`.
//!
//! The same JSON files drive these Rust tests and the Swift `--selftest`. When the two
//! platforms disagree about what the text pipeline should produce, CI fails on both
//! instead of the difference reaching users on one of them.

use std::path::{Path, PathBuf};

/// Absolute path to `core/fixtures/`, resolved at compile time from the crate root.
pub fn dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

/// Read and parse one fixture file. Panics with the offending path, because a missing or
/// malformed fixture is a broken test harness rather than a runtime condition to handle.
pub fn load<T: serde::de::DeserializeOwned>(name: &str) -> T {
    let path = dir().join(name);
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read fixture {}: {e}", path.display()));
    serde_json::from_str(&raw)
        .unwrap_or_else(|e| panic!("cannot parse fixture {}: {e}", path.display()))
}
