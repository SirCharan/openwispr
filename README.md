# OpenWispr

Local-first dictation and meeting transcription for macOS. Speech never leaves your Mac.

100% on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper on the Apple Neural Engine). No cloud, no account, no audio upload — unlike Wispr Flow, which transcribes in the cloud (per its subprocessor list, Aug 2026). Closest open-source sibling: [Muesli](https://github.com/Muesli-HQ/muesli).

## Requirements

- macOS 14.0 or later, Apple Silicon
- ~1.5 GB disk for the default model (downloaded on first launch)

## Features

### Dictation

- **Hybrid trigger.** Tap the hotkey to open a session that stays open until you tap again; hold it past 0.5s for classic push-to-talk (release to transcribe). Default trigger is `fn`; pick Right ⌘, Left ⌃, another modifier, or record a custom shortcut.
- **On-device ASR.** Switch models live — turbo (default, best speed/accuracy), full large-v3 (better on Hindi/Hinglish and other Indic languages), a compressed large, medium, small, base, tiny.
- **Auto-paste at the cursor**, or clipboard-only if you turn auto-paste off or haven't granted Accessibility.
- **Live preview pill** shows a rolling transcript tail while you talk; an **idle mic pill** sits on screen when you're not recording. Both follow the screen your cursor is on.
- **Mute-on-dictate.** Silences whatever's playing through your speakers while you dictate, then restores it — verified by reading the device state back, and recovered automatically if OpenWispr crashes mid-dictation.
- **Languages.** Auto-detect or pick one; output as the original script, Roman transliteration (Hinglish-style), or English translation.
- **File transcription.** Drop or pick an mp3/m4a/wav/mp4/flac file to transcribe on-device.

### Meetings

- Records your mic and the system's output (via ScreenCaptureKit) at once — no bot joins the call.
- Cuts audio at real speech boundaries (Silero VAD) on one shared clock for mic and system audio, so the two sides stay aligned.
- Auto-detects Zoom, Meet and Teams and offers a Start prompt; Zoom speaker names come from the Accessibility roster.
- Per-meeting stats: talk share, words per minute, longest monologue, questions, fillers and interruptions, in the meeting view and Insights.
- When the remote side leaks into your mic, the duplicate mic line is dropped.
- A tunable speech floor drops near-silent chunks before they reach Whisper, so it can't hallucinate filler ("Thank you.", "Gracias.") out of room tone.
- Transcription runs through one ordered queue, so a slow chunk can't scramble the line order or get dropped from a busy meeting.
- At Stop, the full remote-audio recording is split into speakers (on-device diarization via FluidAudio) — rename them afterward.
- Live per-stream health indicators, and the system-audio stream auto-restarts if it dies mid-meeting.
- Transcript checkpoints to disk after every line, so a crash loses at most one chunk.
- Raw audio is kept (mic + system, separately) for 7 days by default, so a bad transcript can be re-run offline.
- Optional AI summary (Decisions / Action items) once the meeting ends, and optional on-device auto-cleanup through Ollama (off by default, per app, raw text kept with revert).

### Google Meet speaker names

Meet names come from a small Chrome extension bundled in the app. Chrome only loads it by hand:

1. In Meetings, click **Set up** on the "Google Meet names" row. Chrome opens `chrome://extensions` and Finder shows the `meet-names` folder.
2. Turn on **Developer mode** (top right of the extensions page).
3. Click **Load unpacked** and pick the `meet-names` folder.

The row turns green once Meet sends its first roster. Without the extension, Meet speakers stay Speaker A/B/C.

### Personalization

- **Snippets** — a spoken trigger phrase expands to canned text (email, LinkedIn, signature). Several trigger phrases per snippet, since Whisper writes the same phrase more than one way.
- **Personal dictionary** — preferred spellings and exact-phrase replacements, fuzzy-matched (Jaro-Winkler + phonetic key) against what Whisper heard.
- **Learns from your corrections** — after a paste, OpenWispr watches for you editing the text and offers to learn the fix.
- **Insights** — words-per-minute, streaks, time saved, and a per-app breakdown of where you dictate.
- **Per-app disable** — turn dictation off in specific apps.

### Privacy

- Transcription runs entirely on-device via WhisperKit. No audio or transcript is sent anywhere unless you turn on an AI feature.
- The AI layer (rewrite styles, meeting summaries) is bring-your-own-key and fully opt-in: a local Ollama model, or an OpenAI-compatible key (OpenAI, OpenRouter). Off by default.

## Install

**Fastest — one line in Terminal (no security prompt):**

```bash
curl -fsSL https://openwispr.vercel.app/install.sh | sh
```

**Or manually:**

1. Download `OpenWispr.dmg` from the [latest release](https://github.com/SirCharan/openwispr/releases/latest).
2. Open the DMG and drag `OpenWispr.app` to `/Applications`.
3. First launch: macOS shows **"OpenWispr" Not Opened** (the build is not notarized). Click **Done**, open **System Settings → Privacy & Security**, scroll to "OpenWispr was blocked", click **Open Anyway**. Terminal alternative: `xattr -dr com.apple.quarantine /Applications/OpenWispr.app`.
4. OpenWispr lives in the menu bar (mic icon), not the Dock. Clicking the app in Applications opens its home window. A setup wizard runs on first launch.

**Not notarized, by choice.** Notarization needs a paid Apple Developer ID, which this project doesn't have — so the DMG is not Apple-signed. `install.sh` clears the quarantine flag for you.

**Homebrew:** `brew install --cask SirCharan/openwispr/openwispr` (cask template in `packaging/openwispr.rb`).

## Permissions

| Permission | Needed for |
|---|---|
| Microphone | Dictation and the mic side of meetings |
| Accessibility | Auto-paste at the cursor. Without it, transcripts land on the clipboard only. |
| Screen Recording | Capturing system audio (the remote side of a meeting), via ScreenCaptureKit |

## Tunables

Settings not exposed in the UI, set via `defaults write org.openwispr.app <key> <type> <value>` — for example `defaults write org.openwispr.app meetingSpeechFloor -float 0.008`:

| Key | Type | Default | What it does |
|---|---|---|---|
| `meetingSpeechFloor` | `-float` | `0.015` | Loudest-half-second RMS a meeting chunk must clear before it's sent to Whisper. Lower it if quiet real speech is getting dropped; raise it if silence is producing hallucinated filler lines. |
| `meetingAudioRetentionDays` | `-int` | `7` | Days to keep raw meeting audio (`~/Documents/OpenWispr/audio`, ~115 MB/hour/stream). `0` turns retention off. |

## Building from source

```bash
git clone https://github.com/SirCharan/openwispr.git
cd openwispr
./build_app.sh          # compiles + assembles build/OpenWispr.app (ad-hoc signed)
open build/OpenWispr.app
./build_dmg.sh           # optional: build/OpenWispr.dmg
```

Headless test gates (`build/OpenWispr.app/Contents/MacOS/OpenWispr <flag>`):

```
--selftest                  pure-logic self-tests (text pipeline, dictionary, snippets, stats, …)
--record-test SECS PATH     mic capture pipeline → WAV
--transcribe-file PATH      full ASR path on a file
--sysaudio-test SECS        ScreenCaptureKit system-audio tap
--concurrency-test PATH     two overlapping transcriptions through one Transcriber
--diarize-test PATH         speaker diarization on a WAV
--mute-test                 mute-on-dictate CoreAudio path, with restore
```

Models cache under `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`. First model load takes ~1–2 min (CoreML compiles for the Neural Engine once, then caches). Builds are signed with a local self-signed identity so mic/Accessibility/Screen Recording grants survive rebuilds instead of re-prompting.

## Command line and URL scheme

The app bundle ships a CLI: `/Applications/OpenWispr.app/Contents/Helpers/openwispr <command>`. Output is JSON (`{ok, command, data, meta, error}`); `transcribe` prints plain text unless you pass `--format json`. Run `openwispr spec` for the full list.

```
openwispr transcribe clip.wav [--model M] [--lang hi]
openwispr history list --limit 5 | get <id> | search <text>
openwispr meetings list | get <stamp>
openwispr dictionary add Kubernetes --replace k8s
openwispr dictation start|stop      openwispr meeting start|stop
```

State changes go through the running app via URLs, which also work from Shortcuts ("Open URL") and scripts: `openwispr://dictation/start|stop`, `openwispr://meeting/start|stop`, `openwispr://open/Meetings`, `openwispr://dictionary/add?term=X&replace=Y`.

## Pricing and trial

The first launch after onboarding starts a 7-day trial with everything on. When it ends, dictation and meetings pause (history, transcripts and summaries stay usable) until you add a license. Then $49 once for a lifetime license on up to 3 Macs, sold through Dodo Payments. The source stays MIT: you can build it yourself. After purchase, `web/thanks.html` shows the key and an "Activate in OpenWispr" link. To set up checkout, replace `DODO_PRODUCT_ID` in the `BUY_URL` constant at the bottom of `web/index.html`.

## Releasing

`./release.sh X.Y.Z --dry-run` bumps the version, builds, zips, makes the DMG, adds the Sparkle appcast item to `web/appcast.xml` and writes the zip sha256 into `packaging/openwispr.rb`. Without `--dry-run` it also commits, pushes, creates the GitHub release, deploys `web/` to Vercel, and prints the tap update step.

Signing: `build_app.sh` uses `$SIGN_ID`, else the first `Developer ID Application` identity, else `Whispr Dev`. A Developer ID build is signed with the hardened runtime and `Resources/OpenWispr.entitlements`, and `release.sh` then notarizes and staples the app and the DMG. Store the notary credentials once: `xcrun notarytool store-credentials openwispr --apple-id <id> --team-id <TEAMID> --password <app-specific-password>`. Self-signed builds print `NOT NOTARIZED`.

## Windows port

In progress, under `windows/` — a Tauri + Rust app (`windows/src-tauri`) sharing the core dictation/text logic with a Rust crate at `core/`, held to the same fixtures (`core/fixtures/`) the Swift self-tests use. `whisper.cpp` is behind an `asr` feature flag so a contributor without CMake can still work on the rest. See `windows/TESTING.md` for the current manual test checklist — a global hotkey and paste-at-cursor can't be exercised on a headless CI runner, so that part is still checked by hand.

## License

MIT
