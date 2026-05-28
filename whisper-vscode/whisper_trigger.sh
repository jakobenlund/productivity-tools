#!/bin/bash
# Trigger script for whisper daemon.
# Phase 1 (idle→recording): starts recording, shows status, exits.
# Phase 2 (recording→done): stops, waits for transcript, pastes it here
#   (paste runs in VS Code terminal context which has accessibility permission).
WHISPER_LANG="${1:-sv}"
SOCKET="/tmp/whisper_daemon.sock"
TRANSCRIPT_FILE="/tmp/whisper_latest_transcript.txt"

if [ ! -S "$SOCKET" ]; then
    echo "❌ Whisper daemon not running."
    echo "   Start it: launchctl load ~/Library/LaunchAgents/com.jakob.whisper-daemon.plist"
    exit 1
fi

STATUS=$(echo '{"action":"status"}' | nc -U "$SOCKET" 2>/dev/null)

if echo "$STATUS" | grep -q '"recording"'; then
    # ── Stop phase ──────────────────────────────────────────────────────────
    rm -f "$TRANSCRIPT_FILE"
    echo "{\"action\":\"toggle\",\"lang\":\"$WHISPER_LANG\"}" | nc -U "$SOCKET" > /dev/null
    echo "⏳  Transcribing..."

    for i in $(seq 1 60); do
        sleep 0.5
        if [ -f "$TRANSCRIPT_FILE" ]; then
            # PyObjC sets clipboard as NSString so VS Code's Electron webview
            # gets correct Unicode (Å Ä Ö). pbcopy raw bytes fail in Electron.
            source ~/.zshrc
            python3 - "$TRANSCRIPT_FILE" <<'PYEOF'
import sys, os, subprocess
from pathlib import Path
from AppKit import NSPasteboard, NSPasteboardTypeString

path = sys.argv[1]
text = Path(path).read_text(encoding="utf-8")
os.unlink(path)

if text.strip():
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)
    subprocess.run(["osascript", "-e",
        'tell application "System Events" to keystroke "v" using command down'])
    print("✅  " + text)
else:
    print("⚠️   Empty transcript — nothing to paste.")
PYEOF
            exit 0
        fi
    done
    echo "❌  Timed out waiting for transcript."

else
    # ── Start phase ─────────────────────────────────────────────────────────
    rm -f "$TRANSCRIPT_FILE"
    echo "{\"action\":\"toggle\",\"lang\":\"$WHISPER_LANG\"}" | nc -U "$SOCKET" > /dev/null
    echo "🎙  Recording [$WHISPER_LANG]... press Ctrl+Shift+E again to stop."
fi
