#!/usr/bin/env bash
# archive-companion.sh — Build, archive, and export the NotchDeck Buddy iOS companion
# for App Store Connect submission.
#
# Preconditions (must be done by you in Xcode / App Store Connect first):
#   1. An App Store Connect record exists for bundle id com.notchdeck.CodeIslandCompanion
#      (new app, version 1.2.0, build 4).
#   2. Xcode is signed in with the Shenzhen Yuanbei team (2VBHV3VJ8N) and
#      "Automatically manage signing" is on for every target, OR you have valid
#      manual provisioning profiles.
#   3. A paid Apple Developer membership is active for the team.
#
# Usage:
#   ./archive-companion.sh            # archive + export a signed .ipa only
#   APPLE_ID=you@x.com APP_SPECIFIC_PASSWORD=xxxx ./archive-companion.sh upload
#       -> after export, also push the .ipa with xcrun altool (legacy; prefer Transporter)
#
# Note on dual-platform (iOS app + watchOS app): archiving the iOS scheme that embeds
# the watch app builds BOTH platform slices into one .xcarchive. This is the same
# behavior as Xcode's Product ▸ Archive. If you prefer the GUI, just use Organizer.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

SCHEME="CodeIslandCompanion"
ARCHIVE_PATH="$PROJECT_DIR/build/NotchDeckBuddy.xcarchive"
IPA_DIR="$PROJECT_DIR/build/ipa"
EXPORT_PLIST="$PROJECT_DIR/ExportOptions.plist"

echo "▸ Archiving scheme '$SCHEME'…"
xcodebuild archive \
  -project CodeIslandCompanion.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates

echo "▸ Exporting signed .ipa (method=app-store)…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$IPA_DIR" \
  -allowProvisioningUpdates

IPA=$(ls -1 "$IPA_DIR"/*.ipa 2>/dev/null | head -1)
echo "✅ IPA ready: $IPA"

if [ "${1:-}" = "upload" ] && [ -n "${APPLE_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ]; then
  echo "▸ Uploading via xcrun altool (legacy path)…"
  xcrun altool --upload-app -f "$IPA" -u "$APPLE_ID" -p "$APP_SPECIFIC_PASSWORD"
else
  echo ""
  echo "Next — upload the IPA to App Store Connect using ONE of:"
  echo "  • Xcode ▸ Organizer ▸ Distribute App ▸ App Store Connect ▸ Upload"
  echo "  • Transporter app: drag $IPA into Transporter"
  echo "  • CLI (legacy): xcrun altool --upload-app -f \"$IPA\" -u <APPLE_ID> -p <APP_SPECIFIC_PASSWORD>"
fi
