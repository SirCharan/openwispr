# Testing OpenWispr on Windows

CI covers everything that runs without a desktop: the text pipeline, the audio maths, the WAV
encoder, the model downloader, the hardware probe, and transcription of a committed fixture.

It cannot cover a global keyboard hook or paste-at-cursor. No GitHub runner has an interactive
desktop session, so no runner can press a key or own the foreground window. This checklist is
the only coverage those two have.

## Setup, once

```powershell
irm https://openwispr.vercel.app/install.ps1 | iex
```

Or from a build:

```powershell
cd windows
npm install
npm run tauri -- build -- --features asr
```

The binary lands at `target\release\openwispr.exe`. Every command below is run from the repo
root in **Windows Terminal** (not the ISE).

## Before the checklist

```powershell
.\target\release\openwispr.exe --hardware        # what this PC can run
.\target\release\openwispr.exe --download-model base.en
.\target\release\openwispr.exe --devices         # is your microphone listed?
.\target\release\openwispr.exe --record-test 3 out.wav
```

`--record-test` prints a live level meter. If the bars stay empty, the microphone is muted or
Windows is blocking desktop apps — the error text names the setting to change. Play `out.wav`
before continuing: if it is silent, nothing further will work.

## W4 — hold-to-talk, paste, per-app disable

Run `.\target\release\openwispr.exe --dictate` and leave it running. It prints one line per
dictation. Nothing below needs the UI, which does not exist yet.

| # | Do this | Expect |
|---|---|---|
| 1 | Open Notepad. Hold **Right Ctrl**, say "this is a test", release | The sentence appears at the cursor. Terminal prints `pasted: This is a test` |
| 2 | Same in **Chrome**'s address bar | Text appears. No lost keystrokes afterwards |
| 3 | Same in **VS Code** and **Slack** | Text appears in both |
| 4 | Tap Right Ctrl and release immediately | `too short — ignored`. Nothing is pasted |
| 5 | Hold Right Ctrl, speak, press **Escape** before releasing | `cancelled`. Nothing is pasted |
| 6 | Press **Ctrl+C** then **Ctrl+V** in Notepad normally | Ordinary copy and paste still work. Holding the trigger has not broken Ctrl |
| 7 | Dictate twice in a row without pausing | Both land. The second is not the first repeated |
| 8 | Dictate into an **elevated** window (Terminal opened as administrator) | Text is *copied*, not pasted, and the note explains that admin windows need OpenWispr elevated. It must not fail silently |
| 9 | Unplug the microphone mid-hold, then release | An error naming the device. No crash, and the next dictation works once it is plugged back in |
| 10 | `--dictate caps-lock`, then hold Caps Lock and speak | Text appears **and capitals do not toggle**. Check the Caps Lock light |
| 11 | With a non-US layout installed, `--dictate right-alt`, then try typing an accented character | Confirms the AltGr warning is real. This is why Right Ctrl is the default |
| 12 | `--dictate key-zz` | Rejects the trigger and lists the valid forms. Exit code 2 |

**Per-app disable** has no UI yet, so it is exercised through the unit tests rather than here.

**If Windows Defender quarantines the binary**, that is the global keyboard hook in an unsigned
exe. Note exactly what Defender reported — it decides whether an EV certificate is worth buying.

## Not yet testable

| Phase | Needs |
|---|---|
| W5 | The app windows: home, settings, history, Insights |
| W6 | Clean-machine first run through the 9-step wizard |
| W7 | `irm \| iex` on a machine with no build tools, then uninstall leaving no registry keys |

## Reporting back

For each numbered row: pass, or the exact terminal output plus what appeared on screen. "Did
not work" cannot be acted on; the printed line usually names the cause.
