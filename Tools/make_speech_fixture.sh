#!/bin/sh
# Tools/make_speech_fixture.sh — regenerate core/fixtures/speech.wav (macOS: say + afconvert).
# `-v Samantha -r 175` is what makes the output byte-identical (sha256 f9a0193a…bd7ec).
set -e
REPO=$(git rev-parse --show-toplevel)
OUT=$REPO/core/fixtures/speech.wav
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say -v Samantha -r 175 "This is a test of the speech recognition system." -o "$TMP/fix.aiff"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/fix.aiff" "$TMP/fix.wav"

# afconvert inserts an 'FLLR' filler chunk (data at offset 4096), but core/src/wav.rs::decode
# assumes the exact 44-byte header wav.rs::encode writes. Strip it and re-emit the header.
mkdir -p "$(dirname "$OUT")"
python3 - "$TMP/fix.wav" "$OUT" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
i, pcm = 12, None
while i + 8 <= len(b):
    cid, sz = b[i:i+4], struct.unpack('<I', b[i+4:i+8])[0]
    if cid == b'data':
        pcm = b[i+8:i+8+sz]
        break
    i += 8 + sz + (sz & 1)
assert pcm is not None and len(pcm) % 2 == 0
sr, ch, bits = 16000, 1, 16
ba = ch * bits // 8
hdr = (b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVE'
       + b'fmt ' + struct.pack('<IHHIIHH', 16, 1, ch, sr, sr * ba, ba, bits)
       + b'data' + struct.pack('<I', len(pcm)))
assert len(hdr) == 44
open(sys.argv[2], 'wb').write(hdr + pcm)
PY
afinfo "$OUT"
shasum -a 256 "$OUT"