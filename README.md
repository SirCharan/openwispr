# Whispr

Local-first voice dictation for macOS. Hold a hotkey, speak, and your words paste at the cursor.
100% on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper on the Apple Neural Engine).
No cloud, no account, no audio leaves your Mac.

Inspired by [Muesli](https://github.com/Muesli-HQ/muesli) — this is the dictation subset.

## Requirements

- macOS 14.0 or later, Apple Silicon
- ~1.5 GB disk for the default model (downloaded on first launch)

## Install (unsigned build)

1. Download `Whispr.app` (or unzip `Whispr.zip`).
2. Move it to `/Applications`.
3. First launch: macOS shows **"Whispr" Not Opened** (the build is not notarized). Click **Done**, open **System Settings → Privacy & Security**, scroll down to "Whispr was blocked", and click **Open Anyway**. Terminal alternative: `xattr -dr com.apple.quarantine /Applications/Whispr.app`. Later launches open normally.
4. Whispr lives in the menu bar (microphone icon) — it has no Dock icon or window.

## First launch

- The menu shows `Whispr — downloading …%` while it fetches the default model
  (`large-v3-v20240930_turbo`, ~1.5 GB), then `loading model…`, then `ready`.
- Grant **Microphone** access when prompted (needed to record).
- Grant **Accessibility** access when prompted (needed to auto-paste with Cmd+V).
  Without it, transcripts are copied to the clipboard and you paste manually.

## Use

- **Hold `⌘⇧D`**, speak, then **release**. The menu-bar icon fills while recording.
- On release Whispr transcribes and pastes the text where your cursor is.

## Settings (menu bar → Settings…)

- **Hotkey** — rebind the push-to-talk shortcut.
- **Model** — switch between turbo / small / base / tiny; it downloads and reloads live.
- **Auto-paste** — turn off for copy-to-clipboard only.
- **Launch at login**.

## Build from source

```bash
git clone https://github.com/SirCharan/whispr.git
cd whispr
./build_app.sh          # compiles + assembles build/Whispr.app (ad-hoc signed)
open build/Whispr.app
```

Headless self-checks:

```bash
./build/Whispr.app/Contents/MacOS/Whispr --selftest                 # WAV encoder
./build/Whispr.app/Contents/MacOS/Whispr --record-test 3 out.wav    # mic capture pipeline
./build/Whispr.app/Contents/MacOS/Whispr --transcribe-file out.wav  # full ASR path
```

## Notes

- First model load takes ~1–2 min (CoreML compiles for the Neural Engine once, then caches).
- Models are cached under `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`.
- Not yet code-signed/notarized — a signed DMG + Homebrew cask are planned.

## License

MIT
