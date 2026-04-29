#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodexProfilesBar"
APP_IDENTIFIER="${APP_IDENTIFIER:-com.codexprofiles.bar}"
APP_VERSION="${APP_VERSION:-2.0.0}"
APP_BUILD="${APP_BUILD:-$(date +%Y%m%d%H%M%S)}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ASSETS_DIR="$ROOT_DIR/Assets"
ICON_FILE="$ASSETS_DIR/AppIcon.icns"

mkdir -p "$DIST_DIR"

echo "Generating app icon..."
"$ROOT_DIR/scripts/generate-icon.py"

echo "Building release binary..."
swift build --package-path "$ROOT_DIR" -c release

BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"

if [ ! -x "$EXECUTABLE" ]; then
  echo "Expected executable not found at: $EXECUTABLE" >&2
  exit 1
fi

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${APP_IDENTIFIER}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

xattr -cr "$APP_BUNDLE" || true

echo "Signing app bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo
echo "App bundle ready:"
echo "  $APP_BUNDLE"
