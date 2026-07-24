# OpenWispr

Local-first voice dictation for macOS. Hold a hotkey, speak, and your words paste at the cursor.
100% on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper on the Apple Neural Engine).
No cloud, no account, no audio leaves your Mac.

Inspired by [Muesli](https://github.com/Muesli-HQ/muesli) — this is the dictation subset.

## Requirements

- macOS 14.0 or later, Apple Silicon
- ~1.5 GB disk for the default model (downloaded on first launch)

## Install (unsigned build)

**Fastest — one line in Terminal (no security prompt):**

```bash
curl -fsSL https://whispr-black-chi.vercel.app/install.sh | sh
```

**Or manually:**

1. Download `OpenWispr.dmg` (or unzip `OpenWispr.zip`).
2. Move it to `/Applications`.
3. First launch: macOS shows **"OpenWispr" Not Opened** (the build is not notarized). Click **Done**, open **System Settings → Privacy & Security**, scroll down to "OpenWispr was blocked", and click **Open Anyway**. Terminal alternative: `xattr -dr com.apple.quarantine /Applications/OpenWispr.app`. Later launches open normally.
4. OpenWispr opens its home window (stats, transcripts, settings) and lives in the menu bar (microphone icon). The setup wizard runs on first launch.

## First launch

- The menu shows `OpenWispr — downloading …%` while it fetches the default model
  (`large-v3-v20240930_turbo`, ~1.5 GB), then `loading model…`, then `ready`.
- Grant **Microphone** access when prompted (needed to record).
- Grant **Accessibility** access when prompted (needed to auto-paste with Cmd+V).
  Without it, transcripts are copied to the clipboard and you paste manually.

## Use

- **Hold the `fn` key** (or your chosen trigger — Right ⌘, Left ⌃, or a custom shortcut), speak, then **release**. A floating pill shows a live preview while recording.
- On release OpenWispr transcribes and pastes the text where your cursor is.

## Settings (menu bar → Settings…)

- **Hotkey** — rebind the push-to-talk shortcut.
- **Model** — switch between turbo / small / base / tiny; it downloads and reloads live.
- **Auto-paste** — turn off for copy-to-clipboard only.
- **Launch at login**.

## Build from source

```bash
git clone https://github.com/SirCharan/openwispr.git
cd openwispr
./build_app.sh          # compiles + assembles build/OpenWispr.app (ad-hoc signed)
open build/OpenWispr.app
```

Headless self-checks:

```bash
./build/OpenWispr.app/Contents/MacOS/OpenWispr --selftest                 # WAV encoder
./build/OpenWispr.app/Contents/MacOS/OpenWispr --record-test 3 out.wav    # mic capture pipeline
./build/OpenWispr.app/Contents/MacOS/OpenWispr --transcribe-file out.wav  # full ASR path
```

## Notes

- First model load takes ~1–2 min (CoreML compiles for the Neural Engine once, then caches).
- Models are cached under `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`.
- Not yet code-signed/notarized — a signed DMG + Homebrew cask are planned.

## License

MIT
