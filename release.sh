#!/bin/bash
#
# NotchDeck 一键发布(Developer ID 直分 + Sparkle)
#
# 用法:
#   ./release.sh 1.2.1 "Release notes..."
#
# 流程:版本号 → build.sh --notarize(编译+签名+公证+DMG)
#       → Sparkle edSignature → appcast.xml → git push → gh release
#
# 前置(仅首次):
#   xcrun notarytool store-credentials "NotchDeck" --apple-id <id> --team-id 2VBHV3VJ8N --password <app-specific>
#   Sparkle 私钥 ~/dev-id-csr/NotchDeck-sparkle-ed25519.pem(勿丢)
#   gh auth login(zt444888-hub)
set -euo pipefail

VERSION="${1:?用法: ./release.sh <版本号,如 1.2.1> [Release 备注]}"
NOTES="${2:-Release $VERSION}"
TEAM="2VBHV3VJ8N"
SIGN_ID="Developer ID Application: Shenzhen Yuanbei Technology Co., Ltd. ($TEAM)"
KEY=~/dev-id-csr/NotchDeck-sparkle-ed25519.pem
cd "$(dirname "$0")"

echo "== 1/6 版本号 $VERSION =="
plutil -replace CFBundleShortVersionString -string "$VERSION" Info.plist
plutil -replace CFBundleVersion -string "$(echo "$VERSION" | tr -d '.')" Info.plist

echo "== 2/6 构建 + 签名 + 公证 + DMG(非沙盒,可能数分钟)=="
SIGN_ID="$SIGN_ID" ./build.sh --notarize

DMG=".build/release/NotchDeck.dmg"
echo "== 3/6 Sparkle 签名 =="
ED=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$DMG" | base64 | tr -d '\n')
LEN=$(stat -f%z "$DMG")
PUB=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
echo "edSignature=$ED  length=$LEN"

echo "== 4/6 更新 appcast.xml =="
python3 - "$VERSION" "$ED" "$LEN" "$PUB" <<'EOF'
import sys, re
version, ed, length, pub = sys.argv[1:5]
xml = open('appcast.xml').read()
item = f"""    <item>
      <title>Version {version}</title>
      <link>https://github.com/zt444888-hub/NotchDeck/releases/tag/v{version}</link>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>{pub}</pubDate>
      <enclosure
        url="https://github.com/zt444888-hub/NotchDeck/releases/download/v{version}/NotchDeck.dmg"
        sparkle:edSignature="{ed}"
        length="{length}"
        type="application/octet-stream" />
    </item>
"""
# 插到 <language>en</language> 之后(保持最新版本在最前)
xml = re.sub(r'(<language>en</language>\s*\n)', r'\1' + item, xml, count=1)
open('appcast.xml','w').write(xml)
print("appcast.xml 已插入", version)
EOF

echo "== 5/6 提交并推送 =="
git add Info.plist appcast.xml
git commit -m "release: v$VERSION" || true
git push origin main

echo "== 6/6 GitHub Release =="
gh release create "v$VERSION" "$DMG" --title "NotchDeck $VERSION" --notes "$NOTES"

echo "✅ 发布完成: https://github.com/zt444888-hub/NotchDeck/releases/tag/v$VERSION"
