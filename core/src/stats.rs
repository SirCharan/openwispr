//! Usage arithmetic behind the home window and the Insights pane.
//!
//! Ported from `Stats.swift` and `OnboardingModel.swift`. Only the pure parts live here;
//! reading and writing the aggregates is the platform's job (UserDefaults on macOS,
//! a settings file on Windows). `fixtures/stats.json` pins the numbers on both.

use crate::history::HistoryEntry;
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate};
use std::collections::{HashMap, HashSet};

/// Hours of typing saved per week, given hours spent typing per day.
///
/// Speech runs about 4x the speed of typing, so roughly three quarters of typing
/// time comes back. Ported from `hoursSavedPerWeek` in `OnboardingModel.swift`.
pub fn hours_saved_per_week(typing_hours_per_day: f64) -> f64 {
    typing_hours_per_day * 0.75 * 7.0
}

/// Consecutive days ending today with at least one entry. Yesterday also counts as the
/// end, so an unused morning does not zero the streak.
pub fn streak(entries: &[HistoryEntry], now: DateTime<Local>) -> u32 {
    if entries.is_empty() {
        return 0;
    }
    let days: HashSet<NaiveDate> = entries.iter().map(|e| e.date.date_naive()).collect();
    let mut cursor = now.date_naive();
    if !days.contains(&cursor) {
        let yesterday = cursor - Duration::days(1);
        if !days.contains(&yesterday) {
            return 0;
        }
        cursor = yesterday;
    }
    let mut count = 0;
    while days.contains(&cursor) {
        count += 1;
        cursor -= Duration::days(1);
    }
    count
}

/// Words per minute over entries that recorded a duration; 0 when none did.
pub fn avg_wpm(entries: &[HistoryEntry]) -> u32 {
    let timed: Vec<&HistoryEntry> = entries
        .iter()
        .filter(|e| e.seconds.unwrap_or(0.0) > 1.0)
        .collect();
    let words: usize = timed.iter().map(|e| e.words()).sum();
    let minutes: f64 = timed.iter().map(|e| e.seconds.unwrap_or(0.0)).sum::<f64>() / 60.0;
    if minutes <= 0.0 {
        return 0;
    }
    (words as f64 / minutes).round() as u32
}

/// Minutes saved against typing: the same words typed at `typing_wpm`, minus the time
/// actually spent speaking. Floors at 0 when speaking was the slower option.
pub fn time_saved_minutes(words: u32, wpm: u32, typing_wpm: u32) -> f64 {
    if words == 0 || typing_wpm == 0 {
        return 0.0;
    }
    let speak = if wpm > 0 {
        words as f64 / wpm as f64
    } else {
        0.0
    };
    (words as f64 / typing_wpm as f64 - speak).max(0.0)
}

/// The typing speed `time_saved_minutes` compares against.
pub const DEFAULT_TYPING_WPM: u32 = 40;

/// Heat intensity 0 to 4 for the streak grid.
pub fn heat_bucket(words: u32, max_words: u32) -> u8 {
    if words == 0 || max_words == 0 {
        return 0;
    }
    let r = words as f64 / max_words as f64;
    if r > 0.66 {
        4
    } else if r > 0.33 {
        3
    } else if r > 0.10 {
        2
    } else {
        1
    }
}

/// Key for the per-day word map, matching the Swift `yyyy-MM-dd` format.
pub fn day_key(date: NaiveDate) -> String {
    format!("{:04}-{:02}-{:02}", date.year(), date.month(), date.day())
}

/// The last `days` days, oldest first, zero-filled.
pub fn daily_series(
    days: u32,
    now: DateTime<Local>,
    map: &HashMap<String, u32>,
) -> Vec<(NaiveDate, u32)> {
    let today = now.date_naive();
    (0..days)
        .rev()
        .map(|back| {
            let day = today - Duration::days(back as i64);
            (day, map.get(&day_key(day)).copied().unwrap_or(0))
        })
        .collect()
}

/// Longest run of consecutive active days in the per-day word map.
pub fn longest_streak(map: &HashMap<String, u32>) -> u32 {
    let mut keys: Vec<&String> = map.iter().filter(|(_, &v)| v > 0).map(|(k, _)| k).collect();
    keys.sort();
    if keys.is_empty() {
        return 0;
    }
    let parse = |s: &str| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok();
    let mut best = 1;
    let mut run = 1;
    for i in 1..keys.len() {
        let (Some(a), Some(b)) = (parse(keys[i - 1]), parse(keys[i])) else {
            continue;
        };
        run = if (b - a).num_days() == 1 { run + 1 } else { 1 };
        best = best.max(run);
    }
    best
}

/// How many days of per-day history to keep before trimming (Swift keeps about 400).
pub const DAILY_WORDS_KEPT: usize = 400;

/// Trim the per-day map to the most recent `DAILY_WORDS_KEPT` days.
pub fn trim_daily_words(map: HashMap<String, u32>) -> HashMap<String, u32> {
    if map.len() <= DAILY_WORDS_KEPT {
        return map;
    }
    let mut keys: Vec<String> = map.keys().cloned().collect();
    keys.sort();
    let cut = keys[keys.len() - DAILY_WORDS_KEPT].clone();
    map.into_iter().filter(|(k, _)| *k >= cut).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct StatsFixtures {
        hours_saved_per_week: Vec<HoursCase>,
        streak: Vec<StreakCase>,
        avg_wpm: Vec<WpmCase>,
        time_saved_minutes: Vec<SavedCase>,
        heat_bucket: Vec<HeatCase>,
        daily_series: Vec<SeriesCase>,
        longest_streak: Vec<LongestCase>,
    }

    #[derive(Deserialize)]
    struct HoursCase {
        typing_hours_per_day: f64,
        expected: f64,
    }

    #[derive(Deserialize)]
    struct EntrySpec {
        days_ago: i64,
        text: String,
        #[serde(default)]
        seconds: Option<f64>,
    }

    #[derive(Deserialize)]
    struct StreakCase {
        entries: Vec<EntrySpec>,
        expected: u32,
    }

    #[derive(Deserialize)]
    struct WpmCase {
        entries: Vec<EntrySpec>,
        expected: u32,
    }

    #[derive(Deserialize)]
    struct SavedCase {
        words: u32,
        wpm: u32,
        #[serde(default = "default_typing_wpm")]
        typing_wpm: u32,
        expected: f64,
    }

    fn default_typing_wpm() -> u32 {
        DEFAULT_TYPING_WPM
    }

    #[derive(Deserialize)]
    struct HeatCase {
        words: u32,
        max: u32,
        expected: u8,
    }

    #[derive(Deserialize)]
    struct SeriesCase {
        days: u32,
        /// Per-day word counts keyed by days ago.
        map_days_ago: HashMap<String, u32>,
        expected_len: usize,
        expected_first: u32,
        expected_last: u32,
    }

    #[derive(Deserialize)]
    struct LongestCase {
        days_ago: Vec<i64>,
        expected: u32,
    }

    fn to_entries(specs: &[EntrySpec], now: DateTime<Local>) -> Vec<HistoryEntry> {
        specs
            .iter()
            .enumerate()
            .map(|(i, s)| {
                HistoryEntry::new(
                    i.to_string(),
                    s.text.clone(),
                    s.seconds,
                    now - Duration::days(s.days_ago),
                )
            })
            .collect()
    }

    fn map_from_days_ago(m: &HashMap<String, u32>, now: DateTime<Local>) -> HashMap<String, u32> {
        m.iter()
            .map(|(days_ago, words)| {
                let back: i64 = days_ago.parse().expect("days_ago must be an integer key");
                (day_key((now - Duration::days(back)).date_naive()), *words)
            })
            .collect()
    }

    #[test]
    fn matches_the_shared_fixtures() {
        let f: StatsFixtures = fixtures::load("stats.json");
        let now = Local::now();

        for c in &f.hours_saved_per_week {
            let got = hours_saved_per_week(c.typing_hours_per_day);
            assert!(
                (got - c.expected).abs() < 0.001,
                "hours_saved_per_week({}) = {got}, want {}",
                c.typing_hours_per_day,
                c.expected
            );
        }
        for c in &f.streak {
            assert_eq!(
                streak(&to_entries(&c.entries, now), now),
                c.expected,
                "streak"
            );
        }
        for c in &f.avg_wpm {
            assert_eq!(avg_wpm(&to_entries(&c.entries, now)), c.expected, "avg_wpm");
        }
        for c in &f.time_saved_minutes {
            let got = time_saved_minutes(c.words, c.wpm, c.typing_wpm);
            assert!(
                (got - c.expected).abs() < 0.001,
                "time_saved_minutes({}, {}) = {got}, want {}",
                c.words,
                c.wpm,
                c.expected
            );
        }
        for c in &f.heat_bucket {
            assert_eq!(heat_bucket(c.words, c.max), c.expected, "heat_bucket");
        }
        for c in &f.daily_series {
            let map = map_from_days_ago(&c.map_days_ago, now);
            let series = daily_series(c.days, now, &map);
            assert_eq!(series.len(), c.expected_len, "daily_series length");
            assert_eq!(series.first().unwrap().1, c.expected_first, "oldest day");
            assert_eq!(series.last().unwrap().1, c.expected_last, "newest day");
        }
        for c in &f.longest_streak {
            let map: HashMap<String, u32> = c
                .days_ago
                .iter()
                .map(|back| (day_key((now - Duration::days(*back)).date_naive()), 5))
                .collect();
            assert_eq!(longest_streak(&map), c.expected, "longest_streak");
        }
    }

    #[test]
    fn trimming_keeps_the_most_recent_days() {
        let map: HashMap<String, u32> = (0..DAILY_WORDS_KEPT + 50)
            .map(|i| (format!("2020-01-{:03}", i), 1))
            .collect();
        let trimmed = trim_daily_words(map);
        assert_eq!(trimmed.len(), DAILY_WORDS_KEPT);
        assert!(trimmed.contains_key(&format!("2020-01-{:03}", DAILY_WORDS_KEPT + 49)));
        assert!(!trimmed.contains_key("2020-01-000"));
    }
}
