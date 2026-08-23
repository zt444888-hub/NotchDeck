# Brand Consistency — NotchDeck / NotchDeck Buddy

This document records the deliberate split between **user-visible branding**
and **internal identifiers** in the NotchDeck project, and why the internal
identifiers are intentionally *not* renamed. It exists so future contributors
don't "helpfully" rename them and accidentally break the Mac ↔ iOS link or the
App Store identity.

## User-visible branding (what we DID rename)

| Surface | Value |
|---|---|
| Mac app product name (`CFBundleName`) | `NotchDeck` |
| Mac DMG / app file | `NotchDeck.dmg` / `NotchDeck.app` |
| iOS app `CFBundleDisplayName` (all 4 targets) | `NotchDeck Buddy` |
| iOS Live Activity title / home hero fallback | `NOTCHDECK BUDDY` |
| iOS Widget extension `CFBundleDisplayName` | `NotchDeck Buddy` |
| Companion source fallback (`CompanionDisplayText.source(nil)`) | `NotchDeck Buddy` |
| README install / build instructions | `NotchDeck.dmg` / `NotchDeck.app` |

## Internal identifiers (intentionally KEPT — do NOT rename)

Renaming any of these breaks a hard contract:

| Identifier | Why it must stay |
|---|---|
| Bundle id `com.notchdeck.CodeIslandCompanion` (+ `.Widget` / `.watchkitapp` / `.watchkitapp.Widget` / `.UITests` / `.Tests`) | App Store identity + CloudKit container binding. Changing it orphans existing installs and the `iCloud.com.notchdeck` container. |
| Module / type names `CodeIsland*`, executable name `CodeIsland` | Referenced across Mac + iOS + watch + helper (`codeisland-bridge`). Renaming cascades through every target. |
| `NSBonjourServices: _codeisland._tcp` | LAN discovery service type. Mac and iOS must advertise/scan the *same* string or they never find each other. |
| MultipeerConnectivity `serviceType = "codeisland"` | The actual session key. Changing it on one side silently severs the Mac↔iOS connection. |
| CoreBluetooth service UUID `6D951BA3-8F41-4C45-9D8A-12085E0D7A10` | BLE discovery filter. Only the UUID is matched — the local name (`NotchDeck Buddy`) is display-only. |
| `CFBundleName: CodeIslandCompanion` (in `InfoPlist.xcstrings`) | Internal module name, not user-visible. |

The Mac(app) → iOS(companion) link therefore relies on `serviceType`,
`_codeisland._tcp`, and the BLE service UUID — all unchanged. The only things a
user ever sees are the display names above, which are fully rebranded.

## Out of scope (separate products, not yet part of the NotchDeck brand)

These are independent sub-products and were deliberately left alone:

- `android-watch/` — a Wear OS experiment (the shipping watch target is Apple Watch).
- `hardware/` — an ESP32 "Buddy" desk toy whose QR code points at the original
  `wxtsky/CodeIsland` repo and draws `Open CodeIsland`.
- `scripts/update-appcast.sh` — **deleted** (pointed at `wxtsky/CodeIsland` and
  was never called by the real release flow, which is `release.sh`).

Rebranding those is a separate decision; the work is tracked but not done.
