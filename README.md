# productivity-tools

macOS productivity tools designed to work with VS Code and Claude Code.

Each tool lives in its own subdirectory with a self-contained installer and README.

## Tools

| Tool | What it does |
|------|-------------|
| [whisper-vscode](./whisper-vscode/) | Instant voice-to-text inside VS Code via OpenAI Whisper. Press a shortcut to start recording, press again to stop — transcript is pasted into whatever is focused. |

## Design philosophy

- **macOS only** — tools use native macOS APIs (LaunchAgents, NSPasteboard, osascript)
- **LLM-assisted setup** — READMEs and install scripts are written to be interpreted by an LLM (Claude, ChatGPT, etc.) which handles the iteration for each user's exact environment
- **Minimal dependencies** — each tool declares exactly what it needs and why

## Adding a tool

Each tool directory should contain:
- `README.md` — setup guide written for LLM interpretation
- `install.sh` — automates everything automatable, prints exact instructions for the rest
- Source files for the tool itself
