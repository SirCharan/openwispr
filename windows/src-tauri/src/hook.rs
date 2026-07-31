//! The global keyboard hook that makes hold-to-talk work.
//!
//! `WH_KEYBOARD_LL` is the only way to see a bare modifier going down and up across the whole
//! desktop. `tauri-plugin-global-shortcut` cannot register Right Ctrl on its own, and
//! hold-a-modifier is the entire interaction, so the raw hook is not optional.
//!
//! Two Win32 rules shape this file:
//!
//! 1. The hook callback runs on the thread that installed it, and that thread must pump
//!    messages. If it stops, Windows silently drops the hook after `LowLevelHooksTimeout`.
//!    So the hook gets its own thread with a `GetMessageW` loop and nothing else in it.
//! 2. Whether to swallow a key must be decided inside the callback, synchronously — the
//!    return value *is* the decision. So the state machine is consulted there, and only the
//!    resulting action is handed to the app over a channel.
//!
//! Nothing here may panic: unwinding out of a callback across the FFI boundary is undefined
//! behaviour. Every lock is a `try_lock`, and a poisoned or busy lock passes the key through.

use crate::trigger::{Action, Machine, Trigger};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// Installed once per process. A second hook on the same trigger would double every event.
static MACHINE: OnceLock<Mutex<Machine>> = OnceLock::new();
static ACTIONS: OnceLock<Mutex<Sender<Action>>> = OnceLock::new();
static CLOCK: OnceLock<Instant> = OnceLock::new();

/// Monotonic milliseconds since the hook started. Monotonic on purpose: a wall clock that
/// steps backwards over a DST change or an NTP correction would produce negative hold times.
#[cfg_attr(not(windows), allow(dead_code))]
fn now_ms() -> u64 {
    CLOCK.get_or_init(Instant::now).elapsed().as_millis() as u64
}

/// Feed one key event to the shared state machine and forward the action.
///
/// Returns true when the key should be swallowed. Separated from the Win32 callback so the
/// dispatch logic is testable on any platform.
#[cfg_attr(not(windows), allow(dead_code))]
fn dispatch(vk: u32, down: bool) -> bool {
    let Some(machine) = MACHINE.get() else {
        return false;
    };
    // try_lock, never lock: blocking inside a low-level hook stalls every keystroke on the
    // machine, and a poisoned mutex would panic across the FFI boundary.
    let Ok(mut machine) = machine.try_lock() else {
        return false;
    };
    let outcome = machine.on_key(vk, down, now_ms());
    if outcome.action != Action::Nothing {
        if let Some(tx) = ACTIONS.get() {
            if let Ok(tx) = tx.try_lock() {
                // A full or disconnected channel must not take the keyboard down with it.
                let _ = tx.send(outcome.action);
            }
        }
    }
    outcome.suppress
}

/// Rebind the trigger while the hook stays installed.
///
/// Not called from the binary yet — the settings UI is W6. Kept because it is part of the
/// hook's contract and the tests cover it.
#[allow(dead_code)]
pub fn set_trigger(trigger: Trigger) -> Option<Action> {
    let machine = MACHINE.get()?;
    let mut machine = machine.lock().ok()?;
    Some(machine.set_trigger(trigger))
}

/// Read by the recording indicator, which arrives with the UI in W5.
#[allow(dead_code)]
pub fn is_recording() -> bool {
    MACHINE
        .get()
        .and_then(|m| m.try_lock().ok())
        .map(|m| m.is_recording())
        .unwrap_or(false)
}

/// Install the hook on its own thread. Returns the channel the app reads actions from.
pub fn install(trigger: Trigger) -> Result<Receiver<Action>, String> {
    let (tx, rx) = channel();
    MACHINE
        .set(Mutex::new(Machine::new(trigger)))
        .map_err(|_| "the keyboard hook is already installed".to_string())?;
    ACTIONS
        .set(Mutex::new(tx))
        .map_err(|_| "the keyboard hook is already installed".to_string())?;
    let _ = CLOCK.get_or_init(Instant::now);
    imp::spawn_hook_thread()?;
    Ok(rx)
}

#[cfg(windows)]
mod imp {
    use super::dispatch;
    use crate::paste::INJECTED_TAG;
    use std::sync::mpsc::channel;
    use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, GetMessageW, SetWindowsHookExW, HC_ACTION, KBDLLHOOKSTRUCT, MSG,
        WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP,
    };

    /// The Win32 callback. Must not panic and must not block.
    unsafe extern "system" fn keyboard_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code == HC_ACTION as i32 {
            let info = unsafe { *(lparam.0 as *const KBDLLHOOKSTRUCT) };
            // Skip our own synthetic Ctrl+V. Without this, pasting a transcript looks like the
            // user pressing Ctrl and starts another dictation.
            if info.dwExtraInfo != INJECTED_TAG {
                let msg = wparam.0 as u32;
                // Alt-combinations arrive as WM_SYSKEY*, so a trigger held with Alt still works.
                let down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
                let up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
                if (down || up) && dispatch(info.vkCode, down) {
                    // Non-zero means "consumed": the key never reaches any other application.
                    return LRESULT(1);
                }
            }
        }
        unsafe { CallNextHookEx(None, code, wparam, lparam) }
    }

    pub fn spawn_hook_thread() -> Result<(), String> {
        let (ready_tx, ready_rx) = channel::<Result<(), String>>();
        std::thread::Builder::new()
            .name("openwispr-keyboard-hook".into())
            .spawn(move || {
                // hmod None + thread id 0 = a global low-level hook for every desktop thread.
                let hook =
                    unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_proc), None, 0) };
                let hook = match hook {
                    Ok(h) => h,
                    Err(e) => {
                        let _ = ready_tx.send(Err(format!(
                            "cannot install the keyboard hook: {e}. Antivirus software \
                             sometimes blocks this; allow OpenWispr and try again."
                        )));
                        return;
                    }
                };
                let _ = ready_tx.send(Ok(()));

                // Pump messages forever. Windows delivers hook callbacks on this thread, and
                // drops the hook if the thread stops responding. The loop body is deliberately
                // empty: GetMessageW blocking IS the keep-alive.
                let mut msg = MSG::default();
                while unsafe { GetMessageW(&mut msg, None, 0, 0) }.as_bool() {}

                // Only reached on WM_QUIT, i.e. at shutdown.
                let _ =
                    unsafe { windows::Win32::UI::WindowsAndMessaging::UnhookWindowsHookEx(hook) };
            })
            .map_err(|e| format!("cannot spawn the hook thread: {e}"))?;

        match ready_rx.recv() {
            Ok(result) => result,
            Err(_) => Err("the hook thread stopped before reporting readiness".into()),
        }
    }
}

#[cfg(not(windows))]
mod imp {
    /// The macOS dev box has no Win32 hook. Installing is a no-op so the rest of the app can
    /// be exercised here; ck verifies the real path on Windows hardware.
    pub fn spawn_hook_thread() -> Result<(), String> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trigger::{vk, CancelReason};

    // These share process-wide statics, so they run as one test rather than racing.
    #[test]
    fn install_then_drive_the_hook_dispatch() {
        let rx = install(Trigger::RightCtrl).expect("install");

        // A second install must be refused: two hooks would double every key event.
        assert!(install(Trigger::CapsLock).is_err());

        assert!(!dispatch(vk::RCONTROL, true), "Ctrl is never swallowed");
        assert_eq!(rx.try_recv(), Ok(Action::Start));
        assert!(is_recording());

        // A key we do not care about produces no action at all.
        assert!(!dispatch(0x41, true));
        assert!(rx.try_recv().is_err(), "no action for unrelated keys");

        assert!(!dispatch(vk::RCONTROL, false));
        match rx.try_recv() {
            Ok(Action::Stop { .. }) => {}
            // Test machines are fast enough that the release can land inside MIN_HOLD_MS.
            Ok(Action::Cancel(CancelReason::TooShort)) => {}
            other => panic!("expected a stop or a too-short cancel, got {other:?}"),
        }
        assert!(!is_recording());

        // Rebinding takes effect without reinstalling.
        assert_eq!(set_trigger(Trigger::CapsLock), Some(Action::Nothing));
        assert!(dispatch(vk::CAPITAL, true), "caps lock must be swallowed");
        assert_eq!(rx.try_recv(), Ok(Action::Start));
        assert!(
            !dispatch(vk::RCONTROL, true),
            "the old trigger is inert after a rebind"
        );
    }

    #[test]
    fn the_clock_is_monotonic() {
        let a = now_ms();
        let b = now_ms();
        assert!(b >= a, "{b} went backwards from {a}");
    }
}
