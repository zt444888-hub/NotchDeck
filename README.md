<h1 align="center">
  <img src="logo.png" width="48" height="48" alt="NotchDeck Logo" valign="middle">&nbsp;
  NotchDeck
</h1>
<p align="center">
  <b>Real-time AI coding agent status panel for macOS Dynamic Island (Notch)</b><br>
  <a href="#installation">Install</a> •
  <a href="#features">Features</a> •
  <a href="#supported-tools">Supported Tools</a> •
  <a href="#build-from-source">Build</a> •
  <a href="PRIVACY.md">Privacy</a><br>
  English | <a href="README.zh-CN.md">简体中文</a>
</p>

---

<p align="center">
  <img src="docs/images/notch-panel.png" width="700" alt="NotchDeck Panel Preview">
</p>

## What is NotchDeck?

NotchDeck lives in your MacBook's notch area and shows you what your AI coding agents are doing — in real time. No more switching windows to check if Claude is waiting for approval or if Codex finished its task.

It connects to **13 AI coding tools** via Unix socket IPC, displaying session status, tool calls, permission requests, and more — all in a compact, pixel-art styled panel.

## Features

- **Notch-native UI** — Expands from the MacBook notch, collapses when idle
- **28 AI tools supported** — Claude Code, Codex, Gemini CLI, Cursor, Copilot, Trae / Trae CN / TraeCli, Qoder / QoderWork, Factory, CodeBuddy / CodyBuddyCN, StepFun, AntiGravity, WorkBuddy, Hermes, Qwen Code, Kimi Code CLI, Cline, Kiro, Pi / Oh My Pi, OpenCode, OpenClaw, ZCode, Google Antigravity
- **Live status tracking** — See active sessions, tool calls, and AI responses in real time
- **Permission management** — Approve/deny tool permissions directly from the panel
- **Question answering** — Respond to agent questions without leaving your current app
- **Pixel-art mascots** — Each AI tool has its own animated character
- **One-click jump** — Click a session to jump to its terminal tab or IDE window
- **Smart suppress** — Tab-level terminal detection: only suppresses notifications when you're looking at the specific session tab, not just the terminal app
- **Sound effects** — Optional 8-bit sound notifications for session events
- **Auto hook install** — Automatically configures hooks for all detected CLI tools, with auto-repair and version tracking
- **iPhone & Apple Watch Buddy** — Mirror session status to Dynamic Island, Lock Screen, StandBy, and Apple Watch
- **Bilingual UI** — English and Chinese, auto-detects system language
- **Multi-display** — Works with external monitors, auto-detects notch displays

## Supported Tools

| | Tool | Type | Status |
|:---:|------|------|--------|
| <img src="docs/images/mascots/claude.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/claude.png" width="16"> Claude Code | Terminal CLI | Full |
| <img src="docs/images/mascots/codex.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/codex.png" width="16"> Codex | Terminal CLI | Full |
| <img src="docs/images/mascots/gemini.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/gemini.png" width="16"> Gemini CLI | Terminal CLI | Full |
| | <img src="Sources/CodeIsland/Resources/cli-icons/kimi.png" width="16"> Kimi Code CLI | Terminal CLI | Full |
| <img src="docs/images/mascots/qoder.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/qoder.png" width="16"> Qoder | Terminal CLI | Full |
| | QoderWork | Desktop app | Full |
| <img src="docs/images/mascots/factory.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/factory.png" width="16"> Factory (droid) | Terminal CLI | Full |
| <img src="docs/images/mascots/codebuddy.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/codebuddy.png" width="16"> CodeBuddy / CodyBuddyCN | Terminal CLI | Full |
| | StepFun | Terminal CLI | Full |
| | AntiGravity | Terminal CLI | Full |
| | WorkBuddy | Terminal CLI | Full |
| | Qwen Code | Terminal CLI | Full |
| | Google Antigravity | IDE/CLI | Full |
| | Hermes (Nous Research) | Terminal CLI | Full |
| | <img src="Sources/CodeIsland/Resources/cli-icons/copilot.png" width="16"> GitHub Copilot CLI | Terminal CLI | Full |
| | <img src="Sources/CodeIsland/Resources/cli-icons/traecli.png" width="16"> TraeCli / Trae CLI Next | Terminal CLI | Full |
| <img src="docs/images/mascots/cursor.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/cursor.png" width="16"> Cursor | IDE | Full |
| <img src="docs/images/mascots/trae.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/traecli.png" width="16"> Trae / Trae CN | IDE | Full (since 1.1.7) |
| <img src="docs/images/mascots/cline.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/cline.png" width="16"> Cline | VSCode extension | Full |
| | Kiro | Terminal CLI | Full |
| <img src="docs/images/mascots/opencode.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/opencode.png" width="16"> OpenCode | Terminal CLI | Full |
| | OpenClaw | Terminal CLI | Full |
| | ZCode | Terminal CLI | Full |
| | <img src="Sources/CodeIsland/Resources/cli-icons/pi.png" width="16"> Pi / Oh My Pi | Terminal CLI | Full |

> **Note on TRAE Work**: TRAE Work mode (the "AI office" desktop app) does **not**
> expose a hook mechanism (product limitation — TRAE only documents hooks for its
> IDE/TraCode product line). NotchDeck works with TRAE IDE / SOLO mode and
> TraeCli; for TRAE Work users we recommend the MCP route (coming soon) or a
> supported CLI such as Claude Code / Codex / Gemini.

## Installation

### Homebrew (Recommended)

```bash
brew tap zt444888-hub/tap
brew install --cask notchdeck
```

### Manual Download

1. Go to [Releases](https://github.com/zt444888-hub/NotchDeck/releases)
2. Download `NotchDeck.dmg`
3. Open the DMG and drag `NotchDeck.app` to your Applications folder
4. Launch NotchDeck — it will automatically install hooks for all detected AI tools

> **Note:** NotchDeck is Developer ID-signed and Apple-notarized, so Gatekeeper normally lets it run without prompts. If a security warning ever appears, go to **System Settings → Privacy & Security** and click **Open Anyway**.

### iPhone & Apple Watch Buddy

NotchDeck Buddy is available on the App Store:

[Download NotchDeck Buddy](https://apps.apple.com/us/app/notchdeck-buddy/idYOUR_BUDDY_APPSTORE_ID)

The iPhone app mirrors your Mac sessions to Dynamic Island, Lock Screen, StandBy, and Apple Watch. The Mac app publishes lightweight session snapshots over your local network while the iPhone app is open, and sends compact Bluetooth summaries for background refreshes such as Live Activities and Watch updates.

NotchDeck Buddy is completely free and open source. It does not require an account or an external server; the companion source code lives in this repository under `ios/CodeIslandCompanion` and `apple-companion`.

### Build from Source

Requires **macOS 14+** and **Swift 5.9+**.

```bash
git clone https://github.com/zt444888-hub/NotchDeck.git
cd NotchDeck

# Development (debug build + launch; Buddy Bluetooth needs the .app below)
swift build && ./.build/debug/NotchDeck

# Release (Apple Silicon / arm64)
./build.sh
open .build/release/NotchDeck.app
```

## How It Works

```
AI Tool (Claude/Codex/Gemini/Cursor/...)
  → Hook event triggered
    → codeisland-bridge (native Swift binary, ~86KB)
      → Unix socket → /tmp/notchdeck-<uid>.sock
        → NotchDeck app receives event
          → Updates UI in real time
          → Optional local Buddy sync to iPhone / Apple Watch
```

NotchDeck installs lightweight hooks into each AI tool's config. When the tool triggers an event (session start, tool call, permission request, etc.), the hook sends a JSON message through a Unix socket. NotchDeck listens on this socket and updates the notch panel instantly.

For **OpenCode**, a JS plugin connects directly to the socket — no bridge binary needed.

## Settings

NotchDeck provides a 7-tab settings panel:

- **General** — Language, launch at login, display selection
- **Behavior** — Auto-hide, smart suppress, session cleanup
- **Appearance** — Panel height, font size, AI reply lines
- **Mascots** — Preview all pixel-art characters and their animations
- **Sound** — 8-bit sound effects for session events
- **Hooks** — View CLI installation status, reinstall or uninstall hooks
- **About** — Version info and links

## Keyboard Shortcuts

| Shortcut | Action | Default |
|----------|--------|---------|
| ⌘⇧I | Toggle the island panel open/closed | On |
| ⌘⇧A | Approve the current permission request | Off |
| ⌘⇧D | Deny the current permission request | Off |

All shortcuts are configurable — and more actions (always-allow, skip question, jump to terminal) can be bound — under **Settings → Shortcuts**. When an approve/deny shortcut is enabled, its binding shows as a badge right on the approval card.

## Requirements

- macOS 14.0 (Sonoma) or later
- Works best on MacBooks with a notch, but also works on external displays

## Acknowledgments

This project was inspired by [claude-island](https://github.com/farouqaldori/claude-island) by [@farouqaldori](https://github.com/farouqaldori). Thanks for the original idea of bringing AI agent status into the macOS notch.

## Star History

<a href="https://www.star-history.com/?repos=wxtsky%2FNotchDeck&type=date&legend=bottom-right">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=zt444888-hub/NotchDeck&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=zt444888-hub/NotchDeck&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=zt444888-hub/NotchDeck&type=date&legend=top-left" />
 </picture>
</a>

## License

MIT License — see [LICENSE](LICENSE) for details.
