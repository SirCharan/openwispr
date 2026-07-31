//! Recent transcripts. Ported from `History.swift`.
//!
//! File IO takes an explicit path so the crate stays platform-free: macOS passes
//! `Application Support/OpenWispr/history.json`, Windows passes its own AppData path.

use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Keep the last 200. Add pagination only if it ever matters.
pub const CAP: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub id: String,
    pub date: DateTime<Local>,
    pub text: String,
    /// Recording duration. Absent in entries written before durations were tracked.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seconds: Option<f64>,
}

impl HistoryEntry {
    pub fn new(id: String, text: String, seconds: Option<f64>, at: DateTime<Local>) -> Self {
        Self {
            id,
            date: at,
            text,
            seconds,
        }
    }

    /// Word count, counting the same way the Swift build does (whitespace-separated, empties dropped).
    pub fn words(&self) -> usize {
        self.text.split(' ').filter(|w| !w.is_empty()).count()
    }
}

/// Newest first, capped. Returns the list to persist.
pub fn add(mut entries: Vec<HistoryEntry>, entry: HistoryEntry) -> Vec<HistoryEntry> {
    entries.insert(0, entry);
    entries.truncate(CAP);
    entries
}

/// Replace one entry's text (in-app transcript correction). Unknown ids are ignored.
pub fn update(entries: &mut [HistoryEntry], id: &str, text: &str) {
    if let Some(e) = entries.iter_mut().find(|e| e.id == id) {
        e.text = text.to_string();
    }
}

/// Missing or malformed files read as empty, matching the Swift build: history is a
/// convenience, and losing it must never block a dictation.
pub fn load(path: &Path) -> Vec<HistoryEntry> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

pub fn save(path: &Path, entries: &[HistoryEntry]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let json = serde_json::to_string(entries)?;
    std::fs::write(path, json)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, text: &str) -> HistoryEntry {
        HistoryEntry::new(id.into(), text.into(), Some(2.0), Local::now())
    }

    #[test]
    fn counts_words_like_the_swift_build() {
        assert_eq!(entry("1", "one two three").words(), 3);
        assert_eq!(entry("1", "  spaced   out  ").words(), 2);
        assert_eq!(entry("1", "").words(), 0);
    }

    #[test]
    fn newest_entry_lands_first() {
        let list = add(vec![entry("old", "old")], entry("new", "new"));
        assert_eq!(list[0].id, "new");
        assert_eq!(list.len(), 2);
    }

    #[test]
    fn the_cap_holds() {
        let mut list: Vec<HistoryEntry> = (0..CAP).map(|i| entry(&i.to_string(), "x")).collect();
        list = add(list, entry("newest", "y"));
        assert_eq!(list.len(), CAP);
        assert_eq!(list[0].id, "newest");
        assert_eq!(list.last().unwrap().id, (CAP - 2).to_string());
    }

    #[test]
    fn update_rewrites_only_the_matching_entry() {
        let mut list = vec![entry("a", "first"), entry("b", "second")];
        update(&mut list, "b", "edited");
        update(&mut list, "missing", "ignored");
        assert_eq!(list[0].text, "first");
        assert_eq!(list[1].text, "edited");
    }

    #[test]
    fn a_missing_file_reads_as_empty() {
        assert!(load(Path::new("/nonexistent/openwispr/history.json")).is_empty());
    }

    #[test]
    fn round_trips_through_disk() {
        let dir = std::env::temp_dir().join("openwispr-core-test-history");
        let path = dir.join("history.json");
        let _ = std::fs::remove_dir_all(&dir);
        let list = vec![entry("a", "hello there")];
        save(&path, &list).expect("save");
        let back = load(&path);
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].text, "hello there");
        assert_eq!(back[0].words(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
