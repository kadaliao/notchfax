#!/bin/bash
# 构建、签名、公证并打包发布文件到 build/release/。
#
#   NOTARY_PROFILE=notary scripts/release.sh
#
# 不给 NOTARY_PROFILE 时只签名、不公证。公证要联网。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -nE 's/^ *CFBundleShortVersionString: "?([^"]+)"?$/\1/p' project.yml)
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Xingyi Liao (HMDAVG9B8J)}"
OUT=build/release
STAGE="$OUT/stage"
DERIVED=build/ReleaseData
rm -rf "$OUT"
mkdir -p "$STAGE"

echo "▸ Notchfax $VERSION"
xcodegen generate --quiet
xcodebuild -project Notchfax.xcodeproj -scheme Notchfax -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build -quiet
ditto "$DERIVED/Build/Products/Release/Notchfax.app" "$STAGE/Notchfax.app"
# 构建目录里不留能直接运行的副本
rm -rf "$DERIVED/Build/Products/Release/Notchfax.app"
codesign --verify --deep --strict "$STAGE/Notchfax.app"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ notarize app"
  ditto -c -k --keepParent "$STAGE/Notchfax.app" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGE/Notchfax.app"
  spctl --assess --type execute "$STAGE/Notchfax.app"
  rm "$OUT/notarize.zip"
fi

# 下载用的磁盘映像：App 旁边放一个「应用程序」的替身
echo "▸ dmg"
DMG="$OUT/Notchfax-$VERSION.dmg"
mkdir -p "$OUT/dmg"
ditto "$STAGE/Notchfax.app" "$OUT/dmg/Notchfax.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Notchfax $VERSION" -srcfolder "$OUT/dmg" -fs APFS -format ULFO -ov "$DMG"
rm -rf "$OUT/dmg"
codesign --sign "$IDENTITY" --timestamp "$DMG"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ notarize dmg"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG"
fi

ditto -c -k --keepParent "$STAGE/Notchfax.app" "$OUT/Notchfax-$VERSION.zip"
# 只留压缩包：散落的 App 副本会出现在聚焦和「打开方式」里
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in "$STAGE/Notchfax.app" "$DERIVED/Build/Products/Release/Notchfax.app"; do
  "$LSREGISTER" -u "$app" 2>/dev/null || true
done
rm -rf "$STAGE"
(cd "$OUT" && shasum -a 256 ./*.dmg ./*.zip | sed 's| \./| |' > SHA256SUMS)
echo "▸ done"
ls -lh "$OUT"
