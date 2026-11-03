# Roadmap

Updated 2026-11-03, after the v0.18.0 release. Ordering reflects user value per unit of work for a solo maintainer. Nothing here is a commitment.

## 1. Meeting quality

Shipped in 0.18.0 (meetings you can trust):

- **Silero VAD segmentation and one shared clock.** Chunks cut at real speech boundaries; mic and system streams share a clock and dropouts are zero-filled.
- **Stream-failure bugs fixed.** The leaked tap, the mic left running after a failed resume, and the silent mic-only meeting.
- **Echo dedup.** Drops the mic twin of a remote line (four tokens or more). Disable with `defaults write org.openwispr.app meetingEchoDedup -bool false`.
- **Per-meeting stats.** Talk share, WPM, monologue, questions, fillers, interruptions, in the meeting view and Insights.
- **Meeting detect.** Zoom, Meet and Teams trigger a Start prompt.
- **Zoom speaker names.** From the Accessibility roster (untested on a live call).
- **Argmax upgrade.** WhisperKit / Argmax 1.1.1 with load-once and download skip.

Still open from this list: audio playback in meeting history, and named speakers that persist across meetings (voice embeddings).

### Next (0.18.x)

- FTS5 transcript search
- Dictation Insights upgrade
- Live transcript view
- Dictation audio playback
- Mic-silent warning
- Language-add nudge
- Meet/Teams OCR speaker-naming spike
- Per-buffer host timestamps
- Hindi engine bench (Hindi2Hinglish Core ML, IndicConformer)

## 2. Dictation and app features

Informed by what Wispr Flow and Muesli ship. OpenWispr stays fully on-device for transcription; AI features stay bring-your-own-key.

| Feature | Why | Effort |
|---|---|---|
| Export meeting as Markdown / PDF | Transcripts are already Markdown internally; unlocks sharing | Low |
| Cleanup tiers (None / Light / Medium / High) + per-app tone | One toggle today; Wispr Flow's tiering is the right shape | Low |
| MCP server over transcript history | Lets Claude/Cursor query your meetings; small surface, developer audience | Low |
| Calendar awareness: detect a meeting, offer one-click record | Removes the "forgot to hit record" failure; Muesli's headline feature | Medium |
| Parakeet ASR backend option | Muesli defaults to it; lower latency than Whisper on Apple Silicon | Medium |
| Command mode: select text, hold trigger, speak an instruction | Wispr Flow's most-cited differentiator; we have the BYOK layer already | Medium |
| Context-aware dictation (read the field, match tone) | Needs accessibility text reads; do after command mode | Medium |
| Streaming dictation preview (true streaming ASR) | Current preview re-transcribes the whole buffer | High |

## 3. Not planned

- **Cross-meeting "Ask Anything" search.** Needs embeddings infrastructure; the MCP server gets most of the value by delegating to a model that already has it.
- **Whisper/subvocal mode, team features, leaderboards.** Different product.
- **Cloud transcription.** On-device is the point.

## Done recently

- v0.18.0 — VAD + shared clock, stream-failure fixes, echo dedup, meeting stats and detect, Zoom names, Argmax 1.1.1, opt-in Ollama cleanup.
- v0.17.1 — hallucinated-filler gate, tunable speech floor measured from a real meeting.
- v0.17.0 — 3-channel mic fix, FIFO transcription, WAV retention, stream health + auto-restart, mute-on-dictate, Indic large-v3, correction learning.
- v0.16.1 — hybrid tap/hold trigger, pills follow the active screen.
