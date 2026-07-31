//! The push-to-talk state machine: which key starts a dictation, and when.
//!
//! Pure and deterministic — the caller supplies the key events and the clock — because the
//! keyboard hook that feeds it cannot be tested in CI. No runner has an interactive desktop,
//! so every rule that can be checked without one is checked here instead.
//!
//! macOS uses the `fn` key. Windows has no equivalent: `fn` is handled in keyboard firmware
//! and never reaches the OS, so the trigger has to be a real modifier.

/// Virtual-key codes, from `WinUser.h`.
pub mod vk {
    pub const CAPITAL: u32 = 0x14;
    pub const ESCAPE: u32 = 0x1B;
    pub const RCONTROL: u32 = 0xA3;
    pub const RMENU: u32 = 0xA5;
}

/// What the user holds to dictate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trigger {
    /// The default. Right Ctrl alone means nothing to Windows, so holding it is safe.
    RightCtrl,
    /// Offered, but AltGr on most non-US layouts — see [`Trigger::warning`].
    RightAlt,
    /// Suppressed while used as a trigger, so it does not toggle caps.
    CapsLock,
    /// Any other single key, by virtual-key code.
    Key(u32),
}

impl Trigger {
    pub fn vk(self) -> u32 {
        match self {
            Trigger::RightCtrl => vk::RCONTROL,
            Trigger::RightAlt => vk::RMENU,
            Trigger::CapsLock => vk::CAPITAL,
            Trigger::Key(code) => code,
        }
    }

    pub fn label(self) -> String {
        match self {
            Trigger::RightCtrl => "Right Ctrl".into(),
            Trigger::RightAlt => "Right Alt".into(),
            Trigger::CapsLock => "Caps Lock".into(),
            Trigger::Key(code) => format!("key 0x{code:02X}"),
        }
    }

    /// Shown next to the option in onboarding when the choice has a cost.
    pub fn warning(self) -> Option<&'static str> {
        match self {
            Trigger::RightAlt => Some(
                "On most non-US keyboard layouts this key is AltGr, which types accented \
                 characters. Holding it to dictate will interfere with that.",
            ),
            Trigger::CapsLock => {
                Some("Caps Lock will no longer toggle capitals while OpenWispr is running.")
            }
            _ => None,
        }
    }

    /// Should the hook swallow this key so the rest of Windows never sees it?
    ///
    /// Only Caps Lock. Swallowing it stops caps toggling on every dictation. A modifier like
    /// Ctrl must pass through: suppressing it would break every Ctrl+key shortcut on the
    /// machine, and holding it alone does nothing anyway.
    pub fn suppresses_key(self) -> bool {
        matches!(self, Trigger::CapsLock)
    }

    /// Parse a stored settings value. Paired with [`Trigger::id`] by the settings file (W6).
    pub fn from_id(id: &str) -> Option<Trigger> {
        match id {
            "right-ctrl" => Some(Trigger::RightCtrl),
            "right-alt" => Some(Trigger::RightAlt),
            "caps-lock" => Some(Trigger::CapsLock),
            other => other
                .strip_prefix("key-")
                .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                .map(Trigger::Key),
        }
    }

    /// Stored in settings so a rebind survives a restart. Written by the settings UI (W6).
    #[allow(dead_code)]
    pub fn id(self) -> String {
        match self {
            Trigger::RightCtrl => "right-ctrl".into(),
            Trigger::RightAlt => "right-alt".into(),
            Trigger::CapsLock => "caps-lock".into(),
            Trigger::Key(code) => format!("key-{code:x}"),
        }
    }
}

/// What the app should do in response to a key event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Begin recording.
    Start,
    /// Stop recording and transcribe. Carries how long the key was held.
    Stop {
        held_ms: u64,
    },
    /// Stop recording and throw the audio away.
    Cancel(CancelReason),
    Nothing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CancelReason {
    /// Released too fast to be speech — a stray tap, not a dictation.
    TooShort,
    /// Escape pressed while recording.
    Escaped,
}

/// Below this, a press is a tap rather than a dictation. Transcribing 80 ms of room noise
/// produces a hallucinated word and pastes it into whatever the user was typing.
pub const MIN_HOLD_MS: u64 = 200;

#[derive(Debug, Clone, Copy)]
pub struct Outcome {
    pub action: Action,
    /// True when the hook must return 1 instead of calling the next hook.
    pub suppress: bool,
}

#[derive(Debug)]
pub struct Machine {
    trigger: Trigger,
    /// When the trigger went down. `None` means not recording.
    pressed_at: Option<u64>,
}

impl Machine {
    pub fn new(trigger: Trigger) -> Self {
        Self {
            trigger,
            pressed_at: None,
        }
    }

    pub fn is_recording(&self) -> bool {
        self.pressed_at.is_some()
    }

    /// Rebind mid-session. Any dictation in flight is abandoned rather than left holding a
    /// key that is no longer the trigger.
    pub fn set_trigger(&mut self, trigger: Trigger) -> Action {
        let was_recording = self.pressed_at.take().is_some();
        self.trigger = trigger;
        if was_recording {
            Action::Cancel(CancelReason::Escaped)
        } else {
            Action::Nothing
        }
    }

    /// Feed one key event. `now_ms` is any monotonic millisecond clock.
    pub fn on_key(&mut self, vk: u32, down: bool, now_ms: u64) -> Outcome {
        // Escape abandons a dictation in progress. It is not suppressed: whatever the user
        // was doing with Escape, they still mean it.
        if down && vk == vk::ESCAPE && self.pressed_at.is_some() {
            self.pressed_at = None;
            return Outcome {
                action: Action::Cancel(CancelReason::Escaped),
                suppress: false,
            };
        }
        if vk != self.trigger.vk() {
            return Outcome {
                action: Action::Nothing,
                suppress: false,
            };
        }
        let suppress = self.trigger.suppresses_key();

        if down {
            // Holding a key repeats WM_KEYDOWN at the system repeat rate. Only the first
            // one starts a dictation; the rest are already-recording no-ops.
            if self.pressed_at.is_some() {
                return Outcome {
                    action: Action::Nothing,
                    suppress,
                };
            }
            self.pressed_at = Some(now_ms);
            Outcome {
                action: Action::Start,
                suppress,
            }
        } else {
            // A key-up with no matching down happens when the trigger was already held as the
            // hook was installed, or after Escape cancelled. Nothing to stop.
            let Some(started) = self.pressed_at.take() else {
                return Outcome {
                    action: Action::Nothing,
                    suppress,
                };
            };
            let held_ms = now_ms.saturating_sub(started);
            let action = if held_ms < MIN_HOLD_MS {
                Action::Cancel(CancelReason::TooShort)
            } else {
                Action::Stop { held_ms }
            };
            Outcome { action, suppress }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn machine() -> Machine {
        Machine::new(Trigger::RightCtrl)
    }

    #[test]
    fn hold_then_release_dictates() {
        let mut m = machine();
        assert_eq!(m.on_key(vk::RCONTROL, true, 1_000).action, Action::Start);
        assert!(m.is_recording());
        assert_eq!(
            m.on_key(vk::RCONTROL, false, 2_500).action,
            Action::Stop { held_ms: 1_500 }
        );
        assert!(!m.is_recording());
    }

    #[test]
    fn a_stray_tap_is_discarded() {
        let mut m = machine();
        m.on_key(vk::RCONTROL, true, 1_000);
        assert_eq!(
            m.on_key(vk::RCONTROL, false, 1_080).action,
            Action::Cancel(CancelReason::TooShort),
            "80 ms is a tap, not speech"
        );
    }

    #[test]
    fn the_boundary_counts_as_a_dictation() {
        let mut m = machine();
        m.on_key(vk::RCONTROL, true, 0);
        assert_eq!(
            m.on_key(vk::RCONTROL, false, MIN_HOLD_MS).action,
            Action::Stop {
                held_ms: MIN_HOLD_MS
            }
        );
    }

    #[test]
    fn key_repeat_does_not_restart_the_recording() {
        let mut m = machine();
        assert_eq!(m.on_key(vk::RCONTROL, true, 100).action, Action::Start);
        // Windows repeats keydown while the key is held.
        for t in [140, 180, 220, 260] {
            assert_eq!(
                m.on_key(vk::RCONTROL, true, t).action,
                Action::Nothing,
                "repeat at {t} must not restart"
            );
        }
        // Held time is measured from the FIRST down, not the last repeat.
        assert_eq!(
            m.on_key(vk::RCONTROL, false, 1_100).action,
            Action::Stop { held_ms: 1_000 }
        );
    }

    #[test]
    fn other_keys_are_ignored_while_recording() {
        let mut m = machine();
        m.on_key(vk::RCONTROL, true, 0);
        for vk in [vk::RMENU, vk::CAPITAL, 0x41, 0xA2 /* left ctrl */] {
            assert_eq!(m.on_key(vk, true, 10).action, Action::Nothing);
        }
        assert!(m.is_recording(), "still recording");
    }

    #[test]
    fn escape_abandons_a_dictation() {
        let mut m = machine();
        m.on_key(vk::RCONTROL, true, 0);
        let out = m.on_key(vk::ESCAPE, true, 500);
        assert_eq!(out.action, Action::Cancel(CancelReason::Escaped));
        assert!(!out.suppress, "Escape must still reach the foreground app");
        assert!(!m.is_recording());
        // The eventual key-up has nothing left to stop.
        assert_eq!(m.on_key(vk::RCONTROL, false, 900).action, Action::Nothing);
    }

    #[test]
    fn escape_when_idle_does_nothing() {
        let mut m = machine();
        assert_eq!(m.on_key(vk::ESCAPE, true, 0).action, Action::Nothing);
    }

    #[test]
    fn a_release_without_a_press_is_ignored() {
        // What happens when the hook is installed while the user already holds the key.
        let mut m = machine();
        assert_eq!(m.on_key(vk::RCONTROL, false, 500).action, Action::Nothing);
    }

    #[test]
    fn caps_lock_is_swallowed_but_ctrl_is_not() {
        let mut caps = Machine::new(Trigger::CapsLock);
        assert!(
            caps.on_key(vk::CAPITAL, true, 0).suppress,
            "otherwise every dictation toggles capitals"
        );
        assert!(caps.on_key(vk::CAPITAL, false, 900).suppress);

        let mut ctrl = machine();
        assert!(
            !ctrl.on_key(vk::RCONTROL, true, 0).suppress,
            "swallowing Ctrl would break every Ctrl+key shortcut"
        );
    }

    #[test]
    fn rebinding_mid_dictation_abandons_it() {
        let mut m = machine();
        m.on_key(vk::RCONTROL, true, 0);
        assert_eq!(
            m.set_trigger(Trigger::CapsLock),
            Action::Cancel(CancelReason::Escaped)
        );
        assert!(!m.is_recording());
        // The old key is now inert, the new one works.
        assert_eq!(m.on_key(vk::RCONTROL, true, 100).action, Action::Nothing);
        assert_eq!(m.on_key(vk::CAPITAL, true, 200).action, Action::Start);
    }

    #[test]
    fn rebinding_while_idle_is_quiet() {
        let mut m = machine();
        assert_eq!(m.set_trigger(Trigger::RightAlt), Action::Nothing);
    }

    #[test]
    fn a_clock_that_goes_backwards_does_not_panic() {
        // saturating_sub, so a non-monotonic clock yields a short hold, not an underflow.
        let mut m = machine();
        m.on_key(vk::RCONTROL, true, 5_000);
        assert_eq!(
            m.on_key(vk::RCONTROL, false, 1_000).action,
            Action::Cancel(CancelReason::TooShort)
        );
    }

    #[test]
    fn ids_round_trip() {
        for t in [
            Trigger::RightCtrl,
            Trigger::RightAlt,
            Trigger::CapsLock,
            Trigger::Key(0x42),
        ] {
            assert_eq!(Trigger::from_id(&t.id()), Some(t), "{}", t.label());
        }
        assert_eq!(Trigger::from_id("nonsense"), None);
        assert_eq!(Trigger::from_id("key-zz"), None);
    }

    #[test]
    fn the_risky_choices_carry_a_warning() {
        assert!(Trigger::RightAlt.warning().unwrap().contains("AltGr"));
        assert!(Trigger::CapsLock.warning().is_some());
        assert!(
            Trigger::RightCtrl.warning().is_none(),
            "the default is safe"
        );
    }
}
