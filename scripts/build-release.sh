#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-2.0.0}"
APP_NAME="ChronoStream"
BUNDLE_DIR="dist/${APP_NAME}.app"
DMG_PATH="dist/${APP_NAME}-${VERSION}-arm64.dmg"
ZIP_PATH="dist/${APP_NAME}-${VERSION}-arm64.zip"
STAGING_DIR="dist/dmg-staging"

echo "==> Building ${APP_NAME} v${VERSION} (release, arm64)..."
swift build -c release

echo "==> Assembling ${BUNDLE_DIR}..."
rm -rf "${BUNDLE_DIR}" "${STAGING_DIR}" "${DMG_PATH}" "${ZIP_PATH}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS" "${BUNDLE_DIR}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUNDLE_DIR}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"

# Stamp version into Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${BUNDLE_DIR}/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${BUNDLE_DIR}/Contents/Info.plist" || true

echo "==> Ad-hoc code signing ${BUNDLE_DIR}..."
codesign --force --deep --sign - "${BUNDLE_DIR}"
codesign --verify --verbose "${BUNDLE_DIR}"

echo "==> Packaging ZIP: ${ZIP_PATH}..."
ditto -c -k --sequesterRsrc --keepParent "${BUNDLE_DIR}" "${ZIP_PATH}"

echo "==> Packaging DMG: ${DMG_PATH}..."
mkdir -p "${STAGING_DIR}"
cp -R "${BUNDLE_DIR}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_PATH}"
rm -rf "${STAGING_DIR}"

echo "==> Generating dist/SHA256SUMS.txt..."
(cd dist && shasum -a 256 "${APP_NAME}-${VERSION}-arm64.dmg" "${APP_NAME}-${VERSION}-arm64.zip" > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt

echo "==> Release build complete!"
