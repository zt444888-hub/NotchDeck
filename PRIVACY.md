# NotchDeck Privacy Policy

Effective date: 2026-08-05

NotchDeck is a local macOS utility that shows real-time AI coding agent status in the Mac notch. It is developed and distributed directly (Developer ID + notarization) and does **not** operate any backend service.

## Data Collection

**The developer does not collect any personal data from NotchDeck.** NotchDeck has no accounts, no telemetry, no analytics SDKs, no advertising SDKs, no tracking SDKs, and no remote logging. We verified this in the source: the app contains no network-beaconing code other than local-device discovery.

## What NotchDeck Reads and Writes Locally

All data processed by NotchDeck stays **on your Mac** in your own user directory:

- **~/.notchdeck/** — NotchDeck's own directory for its helper binary, hook scripts, and usage statistics (`sessions.json`).
- **AI tool configurations** — NotchDeck reads and writes hook entries in the config files of AI tools you use (e.g. Claude Code, Codex, Cursor, Copilot, Gemini CLI, OpenCode, and others). It only touches the hook/extension sections it manages; it does not read or modify your chat history, credentials, or other settings.
- **Token usage statistics** — the "Usage & Cost" page reads locally stored session logs produced by Claude Code and Codex to compute token usage and estimated cost. This computation happens entirely on your machine.
- **Diagnostics export** — if you explicitly trigger it, NotchDeck packages local diagnostics into a file you choose. You control the destination; nothing is sent automatically.

## Local Communication with Your Own Devices

NotchDeck can mirror status to the companion iOS app ("NotchDeck Buddy") on devices you own:

- **Local network (Bonjour/multipeer)** — discovers your Mac so the iPhone can mirror island state.
- **Bluetooth** — used as a lightweight signal for Buddy status updates on iPhone/Apple Watch.

This communication happens only between your own devices on your own network. No third party is involved, and no data is sent to the developer.

## Data Shown in the App

The app displays local session information such as agent name, status, workspace label, recent message previews, and permission requests. This information never leaves your machine except for the optional mirror to your own iPhone/Watch described above.

## No Tracking

NotchDeck does not track you across apps, websites, or devices, and it does not sell or share any data.

## Children

NotchDeck is a developer productivity tool and is not directed to children.

## Changes

This policy may be updated as the app changes. Material changes will be reflected here and in the README before the corresponding release.

## Contact

For questions or concerns, open an issue at:

https://github.com/zt444888-hub/NotchDeck/issues
