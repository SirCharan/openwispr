// A release build is a GUI subsystem binary so launching it never flashes a console.
// `cli::run` re-attaches to the parent console when it needs to print.
#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

mod audio;
mod cli;
mod hardware;
mod models;
mod selftest;

#[cfg(feature = "asr")]
mod asr;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // Headless flags mirror the macOS binary: --selftest, --record-test, --transcribe-file.
    // When one is handled we exit with its code and never open a window.
    if let Some(code) = cli::run(&args) {
        std::process::exit(code);
    }

    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("failed to start OpenWispr");
}
