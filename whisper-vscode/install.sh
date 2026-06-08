#!/usr/bin/env bash
set -euo pipefail

# ── Formatting ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${YELLOW}[→]${NC} $*"; }
hr()   { printf '%.0s─' {1..80}; echo; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.productivity-tools/whisper-vscode"

echo ""
echo -e "${BOLD}WHISPER-VSCODE INSTALLER${NC}"
hr
echo ""

# ── 1. macOS ──────────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || fail "macOS required. See README prerequisites."
ok "macOS $(sw_vers -productVersion)"

# ── 2. Homebrew ───────────────────────────────────────────────────────────────
command -v brew &>/dev/null || fail "Homebrew not found. Install from https://brew.sh then re-run."
ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"

# ── 3. pyenv ──────────────────────────────────────────────────────────────────
command -v pyenv &>/dev/null || fail "pyenv not found.
Install with: brew install pyenv
Then add to ~/.zshrc:
  export PYENV_ROOT=\"\$HOME/.pyenv\"
  export PATH=\"\$PYENV_ROOT/bin:\$PATH\"
  eval \"\$(pyenv init -)\"
Then: source ~/.zshrc  and re-run install.sh"
ok "pyenv $(pyenv --version | awk '{print $2}')"

# ── 4. Python via pyenv ───────────────────────────────────────────────────────
PYTHON_PATH=$(pyenv which python3 2>/dev/null) \
  || fail "No active Python found via pyenv.
Run: pyenv install 3.12.7 && pyenv global 3.12.7 && source ~/.zshrc  then re-run."

PYTHON_VERSION=$("$PYTHON_PATH" --version 2>&1 | awk '{print $2}')
PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)
[[ "$PYTHON_MAJOR" -ge 3 && "$PYTHON_MINOR" -ge 10 ]] \
  || fail "Python 3.10+ required via pyenv. Found: $PYTHON_VERSION
Run: pyenv install 3.12.7 && pyenv global 3.12.7 && source ~/.zshrc  then re-run."

PYENV_BIN=$(dirname "$PYTHON_PATH")
ok "Python $PYTHON_VERSION → $PYTHON_PATH"

# ── 5. ffmpeg ─────────────────────────────────────────────────────────────────
if ! command -v ffmpeg &>/dev/null; then
  info "Installing ffmpeg via Homebrew..."
  brew install ffmpeg
fi
ok "ffmpeg $(ffmpeg -version 2>&1 | head -1 | awk '{print $3}')"

# ── 6. Python packages ────────────────────────────────────────────────────────
info "Installing Python packages (openai sounddevice numpy pyobjc-framework-Cocoa)..."
"$PYTHON_PATH" -m pip install -q openai sounddevice numpy pyobjc-framework-Cocoa
ok "Python packages installed"

# ── 7. Copy scripts ───────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/run"
chmod 700 "$INSTALL_DIR/run"
cp "$SCRIPT_DIR/whisper_daemon.py"  "$INSTALL_DIR/"
cp "$SCRIPT_DIR/whisper_trigger.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/whisper_trigger.sh"
ok "Scripts copied to $INSTALL_DIR"

# ── 8. OpenAI API key ─────────────────────────────────────────────────────────
API_KEY_CONFIGURED=false
if [[ -n "${OPENAI_API_KEY:-}" && "${OPENAI_API_KEY:-}" != "sk-your-key-here" ]]; then
  API_KEY_CONFIGURED=true
elif grep -Eq 'OPENAI_API_KEY=["'\'']?sk-' "$HOME/.zshrc" 2>/dev/null \
  && ! grep -Eq 'OPENAI_API_KEY=["'\'']?sk-your-key-here' "$HOME/.zshrc" 2>/dev/null; then
  API_KEY_CONFIGURED=true
fi

if [[ "$API_KEY_CONFIGURED" != true ]]; then
  fail "OPENAI_API_KEY not found in environment or ~/.zshrc.
Get a key at: https://platform.openai.com/api-keys
Then add to ~/.zshrc:
  export OPENAI_API_KEY=\"sk-your-key-here\"
Run: source ~/.zshrc
Then re-run install.sh"
fi
ok "OpenAI API key configured"

# ── 9. Remove legacy install leftovers ────────────────────────────────────────
LEGACY_PLIST="$HOME/Library/LaunchAgents/com.jakob.whisper-daemon.plist"
if [[ -f "$LEGACY_PLIST" ]]; then
  launchctl unload "$LEGACY_PLIST" 2>/dev/null || true
  rm -f "$LEGACY_PLIST"
  ok "Removed legacy LaunchAgent com.jakob.whisper-daemon"
fi
rm -f /tmp/whisper_daemon.sock /tmp/whisper_latest_transcript.txt

# ── 10. LaunchAgent ───────────────────────────────────────────────────────────
PLIST_DEST="$HOME/Library/LaunchAgents/com.productivity-tools.whisper-daemon.plist"
sed \
  -e "s|{{PYTHON_PATH}}|$PYTHON_PATH|g" \
  -e "s|{{INSTALL_DIR}}|$INSTALL_DIR|g" \
  -e "s|{{PYENV_BIN}}|$PYENV_BIN|g" \
  "$SCRIPT_DIR/launchagent.plist.template" > "$PLIST_DEST"

launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load   "$PLIST_DEST"
ok "LaunchAgent installed → $PLIST_DEST"

for _ in $(seq 1 15); do
  if cat "$INSTALL_DIR/whisper_daemon.log" 2>/dev/null | grep -q "Listening on"; then
    ok "Daemon started successfully"
    break
  fi
  sleep 1
done

if ! cat "$INSTALL_DIR/whisper_daemon.log" 2>/dev/null | grep -q "Listening on"; then
  info "Daemon did not report ready within 15 seconds."
  info "Check: cat $INSTALL_DIR/whisper_daemon.log"
  info "And:   cat $INSTALL_DIR/whisper_daemon.err"
fi

# ── 11. VS Code tasks.json ────────────────────────────────────────────────────
TASKS_FILE="$HOME/Library/Application Support/Code/User/tasks.json"
TRIGGER_PATH="$INSTALL_DIR/whisper_trigger.sh"
info "Updating VS Code tasks.json..."
"$PYTHON_PATH" - "$TASKS_FILE" "$TRIGGER_PATH" <<'PYEOF'
import json, sys
from pathlib import Path

tasks_file = Path(sys.argv[1])
trigger = sys.argv[2]

new_tasks = [
    {
        "label": "Whisper EN",
        "type": "shell",
        "command": f"{trigger} en",
        "presentation": {"reveal": "always", "panel": "shared", "showReuseMessage": False}
    },
    {
        "label": "Whisper SV",
        "type": "shell",
        "command": f"{trigger} sv",
        "presentation": {"reveal": "always", "panel": "shared", "showReuseMessage": False}
    }
]

try:
    content = json.loads(tasks_file.read_text())
    tasks = [t for t in content.get("tasks", []) if not t.get("label", "").startswith("Whisper")]
    tasks.extend(new_tasks)
    content["tasks"] = tasks
except (FileNotFoundError, json.JSONDecodeError):
    content = {"version": "2.0.0", "tasks": new_tasks}

tasks_file.parent.mkdir(parents=True, exist_ok=True)
tasks_file.write_text(json.dumps(content, indent=4) + "\n")
PYEOF
ok "VS Code tasks.json updated"

# ── 12. VS Code keybindings.json ──────────────────────────────────────────────
KB_FILE="$HOME/Library/Application Support/Code/User/keybindings.json"
info "Updating VS Code keybindings.json..."
"$PYTHON_PATH" - "$KB_FILE" <<'PYEOF'
import json, sys
from pathlib import Path

kb_file = Path(sys.argv[1])

entries_block = (
    '    // ── Whisper ───────────────────────────────────────────────────────────────\n'
    '    // Ctrl+Shift+E: record + transcribe (English)\n'
    '    {\n'
    '        "key": "ctrl+shift+e",\n'
    '        "command": "workbench.action.tasks.runTask",\n'
    '        "args": "Whisper EN"\n'
    '    },\n'
    '    // Ctrl+Shift+S: record + transcribe (Swedish)\n'
    '    {\n'
    '        "key": "ctrl+shift+s",\n'
    '        "command": "workbench.action.tasks.runTask",\n'
    '        "args": "Whisper SV"\n'
    '    }'
)

try:
    content = kb_file.read_text()
    if '"Whisper EN"' in content:
        sys.exit(0)  # Already present — nothing to do
    last_bracket = content.rfind(']')
    before = content[:last_bracket].rstrip()
    if before and before[-1] not in (',', '['):
        before += ','
    kb_file.write_text(before + '\n\n' + entries_block + '\n]\n')
except FileNotFoundError:
    new_entries = [
        {"key": "ctrl+shift+e", "command": "workbench.action.tasks.runTask", "args": "Whisper EN"},
        {"key": "ctrl+shift+s", "command": "workbench.action.tasks.runTask", "args": "Whisper SV"}
    ]
    kb_file.parent.mkdir(parents=True, exist_ok=True)
    kb_file.write_text(json.dumps(new_entries, indent=4) + "\n")
PYEOF
ok "VS Code keybindings.json updated"

# ── 13. Manual steps ──────────────────────────────────────────────────────────
echo ""
hr
echo -e "${BOLD}  AUTOMATED SETUP COMPLETE — MANUAL STEP(S) BELOW${NC}"
hr
echo ""

STEP=1

echo -e "${BOLD}STEP $STEP — Privacy and cost${NC}"
hr
cat <<EOF
Before using this tool, confirm you are comfortable with:
  - Microphone audio is sent to the OpenAI Audio Transcriptions API.
  - API usage may cost money on your OpenAI account.
  - Temporary audio files are deleted after transcription by default.
  - To keep WAV recordings for debugging, set WHISPER_SAVE_RECORDINGS=1.
  - Transcribed text is put on the clipboard and pasted into the focused app.

Verification:
  cat "$INSTALL_DIR/whisper_daemon.log" | tail -3
Expected output contains: "Ready. Input device:" and "Listening on $INSTALL_DIR/run/whisper_daemon.sock"
EOF
echo ""
STEP=$((STEP + 1))

# Accessibility
echo -e "${BOLD}STEP $STEP — macOS Accessibility permission${NC}"
hr
cat <<EOF
Open: System Settings → Privacy & Security → Accessibility
Click + and add this exact path:
  $PYTHON_PATH

This allows the daemon to paste transcribed text wherever your cursor is.
On first use, macOS may show an automatic permission dialog — clicking Allow
there is equivalent. If you already clicked Allow, this step is done.
EOF
echo ""
STEP=$((STEP + 1))

# End-to-end test
echo -e "${BOLD}STEP $STEP — End-to-end verification${NC}"
hr
cat <<EOF
1. Open VS Code
2. Click somewhere in a text editor or chat input
3. Press Ctrl+Shift+E
   Expected: terminal panel opens showing:
     🎙  Recording [en] in background.
     This task exits now; press the shortcut again to stop and transcribe.
4. Say a sentence out loud (in English)
5. Press Ctrl+Shift+E again
   Expected: terminal shows:
     ⏳  Transcribing...
     ✅  [your sentence here]
   And the text is pasted where your cursor was.

If recording starts but text does not paste automatically:
  → Re-check System Settings → Privacy & Security → Accessibility
  → The Python binary must have a checkmark: $PYTHON_PATH
  → Cmd+V manually — if text appears, Accessibility permission is missing

If the shortcut does nothing in VS Code:
  → Cmd+Shift+P → "Tasks: Run Task" — confirm "Whisper EN" appears
  → If tasks are missing, re-run install.sh

Full log for debugging:
  cat "$INSTALL_DIR/whisper_daemon.log"
  cat "$INSTALL_DIR/whisper_daemon.err"
EOF
echo ""
hr
echo -e "${GREEN}${BOLD}Done.${NC} Complete the step(s) above to finish setup."
echo ""
