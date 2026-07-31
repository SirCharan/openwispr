//! Logic shared by the macOS and Windows builds of OpenWispr.
//!
//! Nothing in this crate may touch a platform API. Audio capture, hotkeys, paste and
//! transcription live in the platform binaries; this crate holds only the parts that
//! must produce identical output on both. Parity is enforced by `fixtures/` — the same
//! JSON tables drive these tests and the Swift `--selftest`.

pub mod stats;
