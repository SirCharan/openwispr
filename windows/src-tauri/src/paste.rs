//! Putting the transcript where the cursor is, and naming the app that receives it.
//!
//! macOS needs Accessibility permission to synthesize Cmd+V. Windows needs no grant at all:
//! `SendInput` works out of the box. It has a different limit instead — see [`paste`].
//!
//! The non-Windows half exists only so the crate compiles and the pure helpers stay testable
//! on the macOS dev box. Several items have no caller there, which is expected.
#![cfg_attr(not(windows), allow(dead_code))]

/// Where a transcript ended up, so the caller can tell the user the truth.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Delivery {
    /// Typed into the focused window.
    Pasted,
    /// Left on the clipboard for the user to paste. Either they turned auto-paste off, or
    /// the target refused synthetic input.
    Copied,
}

#[cfg(windows)]
mod imp {
    use super::Delivery;
    use std::time::Duration;
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VK_CONTROL, VK_V,
    };
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};
    use windows_core::PWSTR;

    /// Marks our own synthetic keystrokes so the keyboard hook can ignore them. Without it,
    /// the Ctrl we inject to paste looks like the user pressing Ctrl.
    pub const INJECTED_TAG: usize = 0x0057_5350; // "WSP"

    pub fn set_clipboard(text: &str) -> Result<(), String> {
        clipboard_win::set_clipboard_string(text)
            .map_err(|e| format!("cannot write to the clipboard: {e}"))
    }

    /// Send Ctrl+V to whatever has focus.
    fn send_ctrl_v() -> Result<(), String> {
        let key = |vk, up: bool| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: vk,
                    wScan: 0,
                    dwFlags: if up {
                        KEYEVENTF_KEYUP
                    } else {
                        Default::default()
                    },
                    time: 0,
                    dwExtraInfo: INJECTED_TAG,
                },
            },
        };
        // Ctrl down, V down, V up, Ctrl up — in one call, so nothing interleaves.
        let inputs = [
            key(VK_CONTROL, false),
            key(VK_V, false),
            key(VK_V, true),
            key(VK_CONTROL, true),
        ];
        let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
        if sent as usize == inputs.len() {
            Ok(())
        } else {
            // The usual cause is UIPI: a process at higher integrity (an elevated window, or
            // the secure desktop) silently discards synthetic input from a normal process.
            Err(
                "the focused window refused synthetic input (it may be running as \
                 administrator — run OpenWispr as administrator to dictate into it)"
                    .to_string(),
            )
        }
    }

    pub fn paste(text: &str, auto_paste: bool) -> (Delivery, Option<String>) {
        if let Err(e) = set_clipboard(text) {
            return (Delivery::Copied, Some(e));
        }
        if !auto_paste {
            return (Delivery::Copied, None);
        }
        // Windows needs the clipboard content to settle before the target reads it. Without
        // this, fast targets paste the PREVIOUS clipboard entry.
        std::thread::sleep(Duration::from_millis(30));
        match send_ctrl_v() {
            Ok(()) => (Delivery::Pasted, None),
            Err(e) => (Delivery::Copied, Some(e)),
        }
    }

    /// File name of the executable owning the focused window, e.g. "chrome.exe".
    ///
    /// The macOS build keys per-app rules on bundle id. Windows has no such id, so the exe
    /// name is the equivalent handle.
    pub fn foreground_exe() -> Option<String> {
        let hwnd = unsafe { GetForegroundWindow() };
        if hwnd.is_invalid() {
            return None;
        }
        let mut pid = 0u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
        if pid == 0 {
            return None;
        }
        // LIMITED_INFORMATION is the right access here: it is granted for processes at higher
        // integrity, where PROCESS_QUERY_INFORMATION would be denied.
        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?;
        let mut buf = [0u16; 260]; // MAX_PATH
        let mut len = buf.len() as u32;
        let query = unsafe {
            QueryFullProcessImageNameW(
                handle,
                PROCESS_NAME_WIN32,
                PWSTR(buf.as_mut_ptr()),
                &mut len,
            )
        };
        let _ = unsafe { CloseHandle(handle) };
        query.ok()?;
        let full = String::from_utf16_lossy(&buf[..len as usize]);
        super::exe_name_of(&full)
    }
}

#[cfg(not(windows))]
mod imp {
    use super::Delivery;

    // Stubs so the crate builds and its tests run on the macOS dev box. The real paths are
    // Win32-only and get exercised by ck on Windows hardware.
    pub const INJECTED_TAG: usize = 0x0057_5350;

    pub fn paste(_text: &str, _auto_paste: bool) -> (Delivery, Option<String>) {
        (
            Delivery::Copied,
            Some("paste is Windows-only in this build".into()),
        )
    }

    pub fn foreground_exe() -> Option<String> {
        None
    }
}

/// Only the keyboard hook reads this, and only on Windows.
#[cfg(windows)]
pub use imp::INJECTED_TAG;
pub use imp::{foreground_exe, paste};

/// Take the file name off a full executable path.
///
/// Split out from the Win32 call so the parsing is testable on any platform.
pub fn exe_name_of(full_path: &str) -> Option<String> {
    let name = full_path
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or(full_path)
        .trim()
        .trim_end_matches('\0');
    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

/// Is dictation switched off for this app?
///
/// Case-insensitive: Windows paths are, and a user typing "Notepad.exe" into settings means
/// the same thing as "notepad.exe".
pub fn is_disabled_for(exe: Option<&str>, disabled: &[String]) -> bool {
    let Some(exe) = exe else { return false };
    disabled
        .iter()
        .any(|d| d.trim().eq_ignore_ascii_case(exe.trim()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exe_name_comes_off_a_full_path() {
        assert_eq!(
            exe_name_of(r"C:\Program Files\Google\Chrome\Application\chrome.exe").as_deref(),
            Some("chrome.exe")
        );
        assert_eq!(
            exe_name_of(r"C:\Windows\System32\notepad.exe").as_deref(),
            Some("notepad.exe")
        );
        // QueryFullProcessImageNameW writes into a fixed buffer; trailing NULs must not stick.
        assert_eq!(
            exe_name_of("C:\\Windows\\notepad.exe\0\0").as_deref(),
            Some("notepad.exe")
        );
        assert_eq!(exe_name_of("bare.exe").as_deref(), Some("bare.exe"));
        assert_eq!(exe_name_of(""), None);
        assert_eq!(exe_name_of(r"C:\trailing\"), None);
    }

    #[test]
    fn per_app_disable_ignores_case_and_padding() {
        let disabled = vec!["Notepad.exe".to_string(), " keepass.exe ".to_string()];
        assert!(is_disabled_for(Some("notepad.exe"), &disabled));
        assert!(is_disabled_for(Some("NOTEPAD.EXE"), &disabled));
        assert!(is_disabled_for(Some("keepass.exe"), &disabled));
        assert!(!is_disabled_for(Some("chrome.exe"), &disabled));
    }

    #[test]
    fn nothing_is_disabled_when_the_app_is_unknown() {
        // foreground_exe() returns None on a locked screen, and dictation must still work.
        assert!(!is_disabled_for(None, &["notepad.exe".to_string()]));
    }

    #[test]
    fn an_empty_disable_list_blocks_nothing() {
        assert!(!is_disabled_for(Some("notepad.exe"), &[]));
    }

    #[test]
    fn the_injected_tag_is_not_zero() {
        // Zero is what ordinary keystrokes carry, so the tag has to differ or the hook
        // would treat every real keypress as one of ours.
        assert_ne!(imp::INJECTED_TAG, 0);
    }
}
