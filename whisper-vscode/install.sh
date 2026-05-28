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
cp "$SCRIPT_DIR/whisper_daemon.py"  "$INSTALL_DIR/"
cp "$SCRIPT_DIR/whisper_trigger.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/whisper_trigger.sh"
ok "Scripts copied to $INSTALL_DIR"

# ── 8. LaunchAgent ────────────────────────────────────────────────────────────
PLIST_DEST="$HOME/Library/LaunchAgents/com.productivity-tools.whisper-daemon.plist"
sed \
  -e "s|{{PYTHON_PATH}}|$PYTHON_PATH|g" \
  -e "s|{{INSTALL_DIR}}|$INSTALL_DIR|g" \
  -e "s|{{PYENV_BIN}}|$PYENV_BIN|g" \
  "$SCRIPT_DIR/launchagent.plist.template" > "$PLIST_DEST"

launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load   "$PLIST_DEST"
ok "LaunchAgent installed → $PLIST_DEST"

sleep 3
if cat /tmp/whisper_daemon.log 2>/dev/null | grep -q "Listening on"; then
  ok "Daemon started successfully"
else
  info "Daemon may still be starting. Check: cat /tmp/whisper_daemon.log"
fi

# ── 9. Manual steps ───────────────────────────────────────────────────────────
echo ""
hr
echo -e "${BOLD}  AUTOMATED SETUP COMPLETE — MANUAL STEPS BELOW${NC}"
hr
echo ""
echo "The following cannot be automated. Work through each step in order."
echo "Run the verification command at the end of each step before continuing."
echo ""

# Step 1 — API key
echo -e "${BOLD}STEP 1 — OpenAI API key${NC}"
hr
cat <<EOF
Add to ~/.zshrc:
  export OPENAI_API_KEY="sk-your-key-here"

Get a key at: https://platform.openai.com/api-keys

After adding:
  source ~/.zshrc
  launchctl unload ~/Library/LaunchAgents/com.productivity-tools.whisper-daemon.plist
  launchctl load   ~/Library/LaunchAgents/com.productivity-tools.whisper-daemon.plist
  sleep 3

Verification:
  cat /tmp/whisper_daemon.log | tail -3
Expected output contains: "Ready. Input device:" and "Listening on /tmp/whisper_daemon.sock"
EOF
echo ""

# Step 2 — Accessibility
echo -e "${BOLD}STEP 2 — macOS Accessibility permission${NC}"
hr
cat <<EOF
Open: System Settings → Privacy & Security → Accessibility
Click + and add this exact path:
  $PYTHON_PATH

This allows the tool to paste transcribed text into any app via simulated Cmd+V.

Verification (run after granting):
  osascript -e 'tell application "System Events" to keystroke ""'
Expected: no output, exit code 0. If you see an error, the permission was not granted.
EOF
echo ""

# Step 3 — VS Code tasks
TRIGGER_PATH="$INSTALL_DIR/whisper_trigger.sh"
echo -e "${BOLD}STEP 3 — VS Code tasks${NC}"
hr
cat <<EOF
File: ~/Library/Application Support/Code/User/tasks.json

If the file does not exist, create it with exactly this content.
If it exists, merge the two task objects into the existing "tasks" array.

{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Whisper EN",
      "type": "shell",
      "command": "$TRIGGER_PATH en",
      "presentation": {
        "reveal": "always",
        "panel": "shared",
        "showReuseMessage": false
      }
    },
    {
      "label": "Whisper SV",
      "type": "shell",
      "command": "$TRIGGER_PATH sv",
      "presentation": {
        "reveal": "always",
        "panel": "shared",
        "showReuseMessage": false
      }
    }
  ]
}

Verification (in VS Code):
  Cmd+Shift+P → "Tasks: Run Task"
Expected: "Whisper EN" and "Whisper SV" appear in the list
EOF
echo ""

# Step 4 — Keybindings
echo -e "${BOLD}STEP 4 — VS Code keybindings${NC}"
hr
cat <<EOF
File: ~/Library/Application Support/Code/User/keybindings.json

If the file does not exist, create it with exactly this content.
If it exists, add these two objects into the existing top-level array.

[
  {
    "key": "ctrl+shift+e",
    "command": "workbench.action.tasks.runTask",
    "args": "Whisper EN"
  },
  {
    "key": "ctrl+shift+s",
    "command": "workbench.action.tasks.runTask",
    "args": "Whisper SV"
  }
]

Note: ctrl+shift+e and ctrl+shift+s are the defaults. Change them here if they
conflict with existing shortcuts. If you change them, update the "args" values
in tasks.json to match the "label" fields (which you can also rename there).

Verification (in VS Code):
  Cmd+Shift+P → "Open Keyboard Shortcuts (JSON)"
  Confirm the two entries are present and saved.
EOF
echo ""

# Step 5 — End-to-end test
echo -e "${BOLD}STEP 5 — End-to-end verification${NC}"
hr
cat <<EOF
1. Open VS Code
2. Click somewhere in a text editor or chat input
3. Press Ctrl+Shift+E
   Expected: terminal panel opens showing:
     🎙  Recording [en]... press Ctrl+Shift+E again to stop.
4. Say a sentence out loud (in English)
5. Press Ctrl+Shift+E again
   Expected: terminal shows:
     ⏳  Transcribing...
     ✅  [your sentence here]
   And the text is pasted where your cursor was.

If recording starts but text does not paste automatically:
  → Cmd+V manually — if text appears, Step 2 (Accessibility) was not completed
  → Re-do Step 2, then test again

If the shortcut does nothing:
  → Confirm tasks.json is valid JSON (no trailing commas, correct brackets)
  → Confirm the task appears in: Cmd+Shift+P → Tasks: Run Task
  → Confirm keybindings.json is valid JSON

Full log for debugging:
  cat /tmp/whisper_daemon.log
  cat /tmp/whisper_daemon.err
EOF
echo ""
hr
echo -e "${GREEN}${BOLD}Done.${NC} Complete the 5 steps above to finish setup."
echo ""
