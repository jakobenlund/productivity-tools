#!/bin/bash
# Trigger script for whisper daemon.
# Phase 1 (idle→recording): starts recording, shows status, exits.
# Phase 2 (recording→done): stops, waits for transcript, pastes it here
#   (paste runs in VS Code terminal context which has accessibility permission).
WHISPER_LANG="${1:-sv}"
case "$WHISPER_LANG" in
    sv|en) ;;
    *)
        echo "❌ Unsupported language: $WHISPER_LANG"
        echo "   Use: sv or en"
        exit 1
        ;;
esac

RUNTIME_DIR="$HOME/.productivity-tools/whisper-vscode/run"
SOCKET="$RUNTIME_DIR/whisper_daemon.sock"
TRANSCRIPT_FILE="$RUNTIME_DIR/whisper_latest_transcript.txt"
ERROR_FILE="$RUNTIME_DIR/whisper_latest_error.txt"

if [ ! -S "$SOCKET" ]; then
    echo "❌ Whisper daemon not running."
    echo "   Start it: launchctl load ~/Library/LaunchAgents/com.productivity-tools.whisper-daemon.plist"
    exit 1
fi

STATUS=$(echo '{"action":"status"}' | nc -U "$SOCKET" 2>/dev/null)

if echo "$STATUS" | grep -q '"recording"'; then
    # ── Stop phase ──────────────────────────────────────────────────────────
    rm -f "$TRANSCRIPT_FILE"
    rm -f "$ERROR_FILE"
    RESPONSE=$(printf '{"action":"toggle","lang":"%s"}\n' "$WHISPER_LANG" | nc -U "$SOCKET")
    if ! echo "$RESPONSE" | grep -q '"stop_signaled"'; then
        echo "❌ Could not stop recording. Daemon response: $RESPONSE"
        exit 1
    fi
    echo "⏳  Transcribing..."

    for i in $(seq 1 60); do
        sleep 0.5
        if [ -f "$ERROR_FILE" ]; then
            echo "❌  $(cat "$ERROR_FILE")"
            rm -f "$ERROR_FILE"
            exit 1
        fi
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
    echo "   Check: cat ~/.productivity-tools/whisper-vscode/whisper_daemon.log"
    echo "          cat ~/.productivity-tools/whisper-vscode/whisper_daemon.err"

else
    # ── Start phase ─────────────────────────────────────────────────────────
    rm -f "$TRANSCRIPT_FILE"
    rm -f "$ERROR_FILE"
    RESPONSE=$(printf '{"action":"toggle","lang":"%s"}\n' "$WHISPER_LANG" | nc -U "$SOCKET")
    if echo "$RESPONSE" | grep -q '"recording_started"'; then
        echo "🎙  Recording [$WHISPER_LANG] in background."
        echo "   This task exits now; press the shortcut again to stop and transcribe."
    elif echo "$RESPONSE" | grep -q '"busy"'; then
        echo "⏳  Whisper is already transcribing. Wait a few seconds and try again."
    else
        echo "❌ Could not start recording. Daemon response: $RESPONSE"
        exit 1
    fi
fi
