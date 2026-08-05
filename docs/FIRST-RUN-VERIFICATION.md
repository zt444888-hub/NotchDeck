# First-Run Verification Guide

This document describes how to verify NotchDeck v1.1.1 on a clean machine or
account before announcing it to users. These checks validate that:

1. Gatekeeper accepts the downloaded DMG without warnings.
2. The app launches and creates `~/.notchdeck/` with the expected layout.
3. Hooks are installed into each detected AI tool's config on first run.
4. The "Usage & Cost" page renders local usage stats correctly.
5. Sparkle auto-update is wired to `appcast.xml` and checks for newer versions.

## Setup

The recommended setup is a **fresh macOS user account** on any Apple Silicon Mac
running macOS 14+. A new account gives you a clean `~/` (no developer config)
and is the closest substitute for a clean machine when you only own one Mac.

```
System Settings → Users & Groups → Add User…
  Account type: Standard
  Full name: NotchDeck Verify
  Password: anything you remember
```

Sign in to the new account. From this point on, every path below is relative
to that user's home.

## Step 1 — Install the DMG

```bash
open ~/Downloads/NotchDeck.dmg          # double-click works too
cp -R "/Volumes/NotchDeck/NotchDeck.app" /Applications/
hdiutil detach /Volumes/NotchDeck
```

### Pass criteria

- [ ] `spctl --assess --type execute --verbose=4 /Applications/NotchDeck.app`
      prints `accepted` with `source=Notarized Developer ID` (no Gatekeeper prompt).
- [ ] `xcrun stapler validate /Applications/NotchDeck.app` prints `The validate action worked!`.

## Step 2 — First Launch (no AI tool running)

Close any Claude Code, Codex, Cursor, etc. so the installer writes into
quiescent config files. Then:

```bash
open /Applications/NotchDeck.app
```

### Pass criteria

Within ~5 seconds the island should appear in your notch (or above the menu
bar on non-notched displays). You should see:

- [ ] A `~/.notchdeck/` directory created:
      ```bash
      ls -la ~/.notchdeck
      # expect: notchdeck-bridge (executable), notchdeck-hook.sh, sessions.json
      ```
- [ ] Socket created when an AI tool later starts a session:
      ```bash
      ls -la /tmp/notchdeck-*.sock
      ```
- [ ] No popup warnings about accessibility / automation entitlements
      (the app should not request these unless you click into them in Settings).
- [ ] Activity Monitor shows a single `NotchDeck` process (the host app) and
      one `codeisland-bridge` helper when hooks are first invoked.

## Step 3 — Hooks Installation (auto on first launch)

The Settings → Buddy tab has an "Install hooks" / "Re-detect" affordance.
You can also inspect what was written manually:

```bash
# Claude Code
grep -A2 '~/.notchdeck/notchdeck-hook.sh' ~/.claude/settings.json

# Codex
grep -A2 'notchdeck' ~/.codex/config.toml

# Pi / Oh My Pi
grep -l 'NotchDeck pi extension' ~/.pi/agent/extensions/*.ts 2>/dev/null

# OpenClaw
grep -l 'NotchDeck OpenClaw plugin' ~/.openclaw/notchdeck-plugin/*.ts 2>/dev/null
```

### Pass criteria

- [ ] Each detected AI tool has its NotchDeck hook block present.
- [ ] Each CLI tool that has a legacy `CodeIsland` block (if you upgraded an
      existing account) was migrated to `NotchDeck` cleanly.

## Step 4 — Usage & Cost Page

Open Settings → **Usage & Cost**.

### Pass criteria

- [ ] Quota cards render for any installed tool with session history.
- [ ] 30-day bar chart is empty (or populated if you have prior sessions).
- [ ] No crashes when toggling between providers (Claude ↔ Codex).

## Step 5 — Sparkle Auto-Update

NotchDeck 1.1.1 is already the latest release, so Sparkle will *check* but
*not* prompt to update. To verify the update channel end-to-end:

```bash
# Inspect the update URL the running app would hit:
defaults read /Applications/NotchDeck.app/Contents/Info.plist SUFeedURL
# → https://raw.githubusercontent.com/zt444888-hub/NotchDeck/main/appcast.xml

curl -sIL https://raw.githubusercontent.com/zt444888-hub/NotchDeck/main/appcast.xml | head -1
# → HTTP/2 200
```

For a true "user gets prompted" smoke test, do a temporary downgrade on a
*copy* of the app (not your working install):

```bash
cp -R /Applications/NotchDeck.app /tmp/NotchDeck-test.app
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.0" /tmp/NotchDeck-test.app/Contents/Info.plist
codesign --force --sign - /tmp/NotchDeck-test.app      # ad-hoc, no Developer ID needed for local test
open /tmp/NotchDeck-test.app
```

Within ~4 hours (Sparkle's `SUScheduledCheckInterval=14400`), a Sparkle
"update available" sheet should appear, referencing v1.1.1.

### Pass criteria

- [ ] `SUFeedURL` points at the GitHub raw URL and is reachable (HTTP 200).
- [ ] The downgrade trick triggers a Sparkle update sheet referencing v1.1.1.
- [ ] `edSignature` validates (already proven at build time via
      `openssl pkeyutl -verify`, but Sparkle re-verifies it on the client).

## Step 6 — Uninstall (Zap verification)

```bash
brew uninstall --zap --cask zt444888-hub/tap/notchdeck
```

### Pass criteria

- [ ] `/Applications/NotchDeck.app` is gone.
- [ ] `~/.notchdeck/` is removed (the zap trash directive targets it).
- [ ] No dangling `codeisland-bridge` or `~/.claude/hooks/codeisland-*`
      leftovers from the legacy compatibility shim (if any were written).

---

If any check fails, file an issue at
https://github.com/zt444888-hub/NotchDeck/issues with the failing step number
and the exact output (redact any personal paths).