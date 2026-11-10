# Third-party code

OpenWispr ports code and ideas from Muesli, https://github.com/muesli-hq/muesli, MIT.

## Muesli licence

MIT License

Copyright (c) 2026 Pranav Hari

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Files
- `build_app.sh` (Sparkle framework copy + inside-out signing) ← Muesli `scripts/build_native_app.sh`
- `Sources/Whispr/AppFormatting.swift` ← Muesli `DictationAppFormatting.swift`, `DictationPasteSpacing.swift`
- `Sources/Whispr/HotkeyGesture.swift` ← Muesli `HotkeyMonitor.swift` (double-tap timing)
- `Sources/Whispr/DictationHealth.swift` ← Muesli `DictationStartupWatchdog.swift`, `DictationCaptureHealth.swift`
- `Sources/Whispr/RecoveryStore.swift` ← Muesli `DictationRecoveryStore.swift`; Failed section in `HomeWindow.swift` ← `FailedDictationsView.swift`
- `Sources/Whispr/CLI.swift` ← Muesli `MuesliCLI.swift` (JSON envelope, `spec` command)
- `Sources/Whispr/CLI.swift` `skill install` and `skills/openwispr-agent/` ← structure adapted from Muesli `skills/muesli-agent`
