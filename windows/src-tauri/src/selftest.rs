//! Built-in checks, run by `openwispr.exe --selftest`.
//!
//! The macOS binary has the same flag. CI runs both, so a check that exists on one
//! platform and not the other is a gap worth noticing. Returns a process exit code.

type Check = (&'static str, fn() -> Result<(), String>);

const CHECKS: &[Check] = &[("stats.hours_saved_per_week", check_hours_saved)];

pub fn run() -> i32 {
    let mut failed = 0;
    for (name, check) in CHECKS {
        match check() {
            Ok(()) => println!("PASS {name}"),
            Err(reason) => {
                println!("FAIL {name}: {reason}");
                failed += 1;
            }
        }
    }
    let total = CHECKS.len();
    println!("{}/{} checks passed", total - failed, total);
    if failed == 0 {
        0
    } else {
        1
    }
}

fn check_hours_saved() -> Result<(), String> {
    let got = openwispr_core::stats::hours_saved_per_week(3.0);
    if (got - 15.75).abs() < 0.001 {
        Ok(())
    } else {
        Err(format!("expected 15.75 for 3 h/day, got {got}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_checks_pass() {
        assert_eq!(run(), 0);
    }

    #[test]
    fn check_names_are_unique() {
        let mut names: Vec<&str> = CHECKS.iter().map(|(n, _)| *n).collect();
        names.sort_unstable();
        let count = names.len();
        names.dedup();
        assert_eq!(names.len(), count, "duplicate check name");
    }
}
