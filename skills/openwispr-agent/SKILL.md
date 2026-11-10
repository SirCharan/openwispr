---
name: openwispr
description: ck's dictation and meeting history, transcription and summaries via the openwispr CLI
---

# OpenWispr agent skill

Use the `openwispr` CLI to read the user's dictation history and saved meetings, transcribe audio files, and add dictionary terms. Every command prints one JSON envelope: `{ok, command, data, meta:{version}, error}`.

## Find the CLI

Run `scripts/resolve_openwispr.sh`. It prints the path to `openwispr` (installed app first, then the repo build). Use that path below as `$OW`.

## Common tasks

- Recent dictation: `$OW history list --limit 20`; search with `$OW history search <query>`.
- Meetings: `$OW meetings list`, then `$OW meetings get <stamp>` (transcript lines plus the summary when one is saved).
- Transcribe a file: `$OW transcribe <file> [--lang L]`.
- Teach a word: `$OW dictionary add <term> [--replace <text>]`.
- Start/stop recording: `dictation start|stop`, `meeting start|stop`. These go through the running app and are blocked when the trial has ended.

## Rules

- Reads are safe. Only start or stop recording when the user asks.
- Transcripts are private user data: quote what is needed, never paste whole meetings elsewhere.
- Full command list: `references/cli-contract.md`.
