# whisper-vscode

Voice-to-text inside VS Code via OpenAI Whisper. Speak — transcript is pasted
wherever your cursor is.

## Two modes

| | Standalone | Daemon |
|---|---|---|
| **How** | `python3 transcribe.py` in a terminal, press Enter to stop | Keyboard shortcut, no terminal needed |
| **Startup** | 2–3s delay (Python loads each time) | Instant (daemon pre-warmed at login) |
| **Setup** | Minimal — just Python + API key | Requires LaunchAgent + VS Code config |
| **File** | `transcribe.py` | `whisper_daemon.py` + `whisper_trigger.sh` |

**Start with standalone mode** if you want the simplest possible setup.
Switch to daemon mode when the startup delay becomes annoying.

Both modes use the same OpenAI Whisper API and support Swedish and English.

---

## Daemon mode

Press a keyboard shortcut to start recording, press again to stop — transcript
is pasted wherever your cursor is.

**How it works:**
- A Python daemon starts at login and keeps the Whisper client loaded in memory
- Pressing the shortcut sends a toggle signal to the daemon via a Unix socket
- Recording happens on a dedicated microphone (not your Bluetooth headphones)
- Transcription uses the OpenAI Whisper API (cloud, not local model)
- The result is pasted via macOS NSPasteboard + System Events

**Default shortcuts:** `Ctrl+Shift+E` (English) · `Ctrl+Shift+S` (Swedish)
These are configurable — see Step 4 of setup.

---

## FOR THE SETUP LLM

This README is written to be interpreted by an LLM assisting the new user.
Work through the steps in order. Each step has a verification command — run it
and confirm the expected output before moving on. If a step fails, diagnose and
fix before continuing; do not skip steps.

---

## Standalone mode (quick start)

Requires only Python 3, ffmpeg, and an OpenAI API key — no daemon, no VS Code config.

```bash
# Install dependencies
brew install ffmpeg
pip3 install openai sounddevice numpy

# Add to ~/.zshrc, then: source ~/.zshrc
export OPENAI_API_KEY="sk-your-key-here"

# Run
python3 transcribe.py        # Swedish (default)
python3 transcribe.py en     # English
```

The script records until you press Enter, then transcribes and pastes the result.
macOS will prompt for Accessibility permission on first use — click Allow.

To change the preferred microphone, edit `PREFERRED_INPUT_DEVICES` at the top of
`transcribe.py`. Run this to see available devices:
```bash
python3 -c "import sounddevice as sd; [print(i, d['name']) for i, d in enumerate(sd.query_devices()) if d['max_input_channels'] > 0]"
```

---

## Daemon mode — Prerequisites

Run these checks first. Fix anything that fails before running `install.sh`.

### 1. macOS version

```bash
sw_vers -productVersion
```
Expected: `13.x` or higher. This tool does not support Linux or Windows.

### 2. Homebrew

```bash
brew --version
```
Expected: `Homebrew 4.x.x` or similar.
If missing: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`

After installing on Apple Silicon, also run:
```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc && source ~/.zshrc
```

### 3. pyenv

```bash
pyenv --version
```
Expected: `pyenv 2.x.x` or similar.
If missing:
```bash
brew install pyenv
```
Then add to `~/.zshrc`:
```
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
```
Then: `source ~/.zshrc`

### 4. Python 3.10+ via pyenv

```bash
pyenv versions
```
Expected: at least one version `3.10.x` or higher listed, with one marked as active (asterisk `*`).

If no suitable version is installed:
```bash
pyenv install 3.12.7
pyenv global 3.12.7
source ~/.zshrc
```

Verify the right Python is active:
```bash
pyenv which python3
```
Expected: a path like `/Users/USERNAME/.pyenv/versions/3.12.7/bin/python3`

### 5. OpenAI API key

```bash
echo $OPENAI_API_KEY
```
Expected: a string starting with `sk-`.
If empty: get a key at https://platform.openai.com/api-keys, then add to `~/.zshrc`:
```
export OPENAI_API_KEY="sk-your-key-here"
```
Then: `source ~/.zshrc`

---

## Installation

Once all prerequisites pass, run from inside the `whisper-vscode/` directory:

```bash
chmod +x install.sh && ./install.sh
```

The installer will:
- Install `ffmpeg` via Homebrew if missing
- Install required Python packages
- Copy scripts to `~/.productivity-tools/whisper-vscode/`
- Generate a LaunchAgent plist with the correct Python path and install it
- Start the daemon immediately
- Print exact instructions for the remaining manual steps

---

## Manual steps after install.sh

The installer will print these with your exact paths filled in, but here is
what to expect:

### Step A — VS Code tasks

Open (create if missing): `~/Library/Application Support/Code/User/tasks.json`

Add the two Whisper tasks into the `"tasks"` array. The installer prints the
exact JSON with your install path already substituted.

### Step B — VS Code keybindings

Open (create if missing): `~/Library/Application Support/Code/User/keybindings.json`

Add the two keybinding entries into the top-level array. The installer prints them.

Note: `ctrl+shift+s` and `ctrl+shift+e` are the defaults. If either conflicts
with another shortcut, choose different keys and update both the keybindings and
the task `"args"` to match.

### Step C — macOS Accessibility permission

The paste step requires Accessibility access for the Python binary.

Open: **System Settings → Privacy & Security → Accessibility**
Click `+` and add the Python binary path (the installer prints the exact path).

---

## Verification

After completing all steps:

```bash
# 1. Confirm daemon is running
cat /tmp/whisper_daemon.log | tail -3
```
Expected: `[HH:MM:SS] Ready. Input device: ...` and `[HH:MM:SS] Listening on /tmp/whisper_daemon.sock`

```bash
# 2. Confirm socket exists
ls -la /tmp/whisper_daemon.sock
```
Expected: `srwxr-xr-x ... /tmp/whisper_daemon.sock`

```bash
# 3. Trigger test (start then stop immediately)
~/.productivity-tools/whisper-vscode/whisper_trigger.sh en
# wait 1 second, then:
~/.productivity-tools/whisper-vscode/whisper_trigger.sh en
```
Expected first output: `🎙  Recording [en]...`
Expected second output: `⏳  Transcribing...` followed by `✅  [empty or short transcript]`

```bash
# 4. Confirm full transcript flow in VS Code
```
In VS Code: press `Ctrl+Shift+E`, say a sentence, press `Ctrl+Shift+E` again.
The terminal panel should show `✅  [your sentence]` and the text should appear
wherever your cursor was.

---

## Troubleshooting

### Daemon not starting

```bash
cat /tmp/whisper_daemon.err
```
Common causes:
- `OPENAI_API_KEY not found` → add key to `~/.zshrc`, reload daemon
- Python package missing → re-run `install.sh`
- Port/socket conflict → `rm /tmp/whisper_daemon.sock` and reload daemon

Reload daemon:
```bash
launchctl unload ~/Library/LaunchAgents/com.productivity-tools.whisper-daemon.plist
launchctl load  ~/Library/LaunchAgents/com.productivity-tools.whisper-daemon.plist
sleep 3 && cat /tmp/whisper_daemon.log | tail -5
```

### Shortcut does nothing in VS Code

- Confirm `tasks.json` is saved and valid JSON
- In VS Code: `Cmd+Shift+P` → `Tasks: Run Task` → you should see "Whisper EN" and "Whisper SV"
- If tasks appear there but shortcut doesn't work: check `keybindings.json` for conflicts

### Text pastes with wrong characters (broken Å Ä Ö etc.)

The paste uses PyObjC (`NSPasteboardTypeString`). If characters are wrong:
```bash
python3 -c "from AppKit import NSPasteboard; print('PyObjC OK')"
```
If this fails: `pip install pyobjc-framework-Cocoa`

### Transcription is slow

Expected latency after pressing stop: 2–5 seconds for short recordings.
The daemon is pre-warmed so recording starts instantly; the delay is the Whisper API call.

### Recording from wrong microphone

The daemon prefers `Logitech Webcam C925e` then `MacBook Pro` built-in.
To see available devices:
```bash
python3 -c "import sounddevice as sd; [print(i, d['name']) for i, d in enumerate(sd.query_devices()) if d['max_input_channels'] > 0]"
```
To change preference, edit `PREFERRED_INPUT_DEVICES` at the top of `~/.productivity-tools/whisper-vscode/whisper_daemon.py` and reload the daemon.

---

## Files installed

| Path | Purpose |
|------|---------|
| `~/.productivity-tools/whisper-vscode/whisper_daemon.py` | Background daemon |
| `~/.productivity-tools/whisper-vscode/whisper_trigger.sh` | Shortcut trigger |
| `~/Library/LaunchAgents/com.productivity-tools.whisper-daemon.plist` | Auto-start at login |
| `~/recordings/` | WAV recordings saved here (created on first use) |
| `/tmp/whisper_daemon.log` | Daemon log |
| `/tmp/whisper_daemon.err` | Daemon error log |
| `/tmp/whisper_daemon.sock` | Unix socket |

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.productivity-tools.whisper-daemon.plist
rm ~/Library/LaunchAgents/com.productivity-tools.whisper-daemon.plist
rm -rf ~/.productivity-tools/whisper-vscode
```
Then remove the tasks and keybinding entries from VS Code config.
