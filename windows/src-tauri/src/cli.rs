//! Headless command-line flags, mirroring the macOS binary's `--selftest` family.
//!
//! `run` returns `Some(exit_code)` when it handled a flag, `None` to continue into the GUI.

use crate::selftest;

pub fn run(args: &[String]) -> Option<i32> {
    let flag = args.first()?;
    match flag.as_str() {
        "--selftest" => {
            attach_console();
            Some(selftest::run())
        }
        "--version" | "-v" => {
            attach_console();
            println!("OpenWispr {}", env!("CARGO_PKG_VERSION"));
            Some(0)
        }
        "--help" | "-h" => {
            attach_console();
            println!("{USAGE}");
            Some(0)
        }
        other if other.starts_with('-') => {
            attach_console();
            eprintln!("unknown flag: {other}\n\n{USAGE}");
            Some(2)
        }
        // Not a flag: let the GUI start (Windows passes stray arguments on file-association launches).
        _ => None,
    }
}

const USAGE: &str = "\
OpenWispr — local-first voice dictation.

Run with no arguments to start the app. Headless flags:

  --selftest    run the built-in checks, print PASS/FAIL per check
  --version     print the version
  --help        print this message";

/// Reattach stdout/stderr to the console that launched us.
///
/// A GUI subsystem binary starts with no console, so `println!` silently goes nowhere.
/// Without this, CI would assert against empty output and pass by accident.
#[cfg(windows)]
fn attach_console() {
    use windows::Win32::System::Console::{AttachConsole, ATTACH_PARENT_PROCESS};
    // Fails when there is no parent console (double-clicked). Nothing to print to, so ignore.
    let _ = unsafe { AttachConsole(ATTACH_PARENT_PROCESS) };
}

#[cfg(not(windows))]
fn attach_console() {}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn no_arguments_starts_the_gui() {
        assert_eq!(run(&[]), None);
    }

    #[test]
    fn a_stray_path_starts_the_gui() {
        assert_eq!(run(&args(&["C:\\note.txt"])), None);
    }

    #[test]
    fn unknown_flags_exit_two() {
        assert_eq!(run(&args(&["--wat"])), Some(2));
    }

    #[test]
    fn version_and_help_exit_zero() {
        assert_eq!(run(&args(&["--version"])), Some(0));
        assert_eq!(run(&args(&["--help"])), Some(0));
    }
}
