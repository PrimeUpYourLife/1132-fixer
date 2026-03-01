#!/usr/bin/env bash
set -euo pipefail

APP_NAME="1132 Fixer"
EXECUTABLE_NAME="1132 Fixer"
TARGET_NAME="1132Fixer"
BUNDLE_ID="com.local.1132fixer"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
MIN_MACOS_FILE="$ROOT_DIR/MIN_MACOS_VERSION"
DIST_DIR="$ROOT_DIR/dist"
TEMP_BUILD_ROOT="$ROOT_DIR/.build/universal"
ARM64_BUILD_DIR="$TEMP_BUILD_ROOT/arm64"
X64_BUILD_DIR="$TEMP_BUILD_ROOT/x86_64"
UNIVERSAL_DIR="$TEMP_BUILD_ROOT/merged"
APP_BUNDLE_DIR="$DIST_DIR/$APP_NAME.app"
APP_VERSION="${APP_VERSION:-}"
APP_BUILD="${APP_BUILD:-1}"
# Determine minimum macOS version from environment or config file to avoid
# duplicating the value defined elsewhere (e.g., in Package.swift).
MIN_MACOS="${MIN_MACOS:-}"
if [[ -z "$MIN_MACOS" ]]; then
  if [[ -f "$MIN_MACOS_FILE" ]]; then
    MIN_MACOS="$(tr -d '[:space:]' < "$MIN_MACOS_FILE")"
  fi
fi
if [[ -z "$MIN_MACOS" ]]; then
  echo "MIN_MACOS is empty. Set MIN_MACOS or populate $MIN_MACOS_FILE." >&2
  exit 1
fi

if [[ -z "$APP_VERSION" ]]; then
  if [[ -f "$VERSION_FILE" ]]; then
    APP_VERSION="$(tr -d '\n\r' < "$VERSION_FILE")"
  else
    echo "Missing VERSION file: $VERSION_FILE" >&2
    exit 1
  fi
fi

if [[ -z "$APP_VERSION" ]]; then
  echo "APP_VERSION is empty. Set APP_VERSION or populate $VERSION_FILE." >&2
  exit 1
fi

DMG_PATH="$DIST_DIR/$APP_NAME-v$APP_VERSION-universal.dmg"
DMG_STAGING_DIR="$TEMP_BUILD_ROOT/dmg-staging"

# Required for distribution: Developer ID Application identity from your keychain.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

# Set NOTARIZE=0 to skip notarization.
NOTARIZE="${NOTARIZE:-1}"

# Notarization credentials (required when NOTARIZE=1).
APPLE_API_KEY_ID="${APPLE_API_KEY_ID:-}"
APPLE_API_ISSUER_ID="${APPLE_API_ISSUER_ID:-}"
APPLE_API_PRIVATE_KEY="${APPLE_API_PRIVATE_KEY:-}"
APPLE_API_KEY_PATH="${APPLE_API_KEY_PATH:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "Missing SIGN_IDENTITY. Example:" >&2
  echo "  SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' $0" >&2
  exit 1
fi

rm -rf "$DIST_DIR" "$TEMP_BUILD_ROOT"
mkdir -p "$DIST_DIR" "$UNIVERSAL_DIR"

echo "==> Building arm64 release binary"
swift build -c release --arch arm64 --scratch-path "$ARM64_BUILD_DIR"

echo "==> Building x86_64 release binary"
swift build -c release --arch x86_64 --scratch-path "$X64_BUILD_DIR"

ARM64_BIN="$ARM64_BUILD_DIR/release/$EXECUTABLE_NAME"
X64_BIN="$X64_BUILD_DIR/release/$EXECUTABLE_NAME"
UNIVERSAL_BIN="$UNIVERSAL_DIR/$EXECUTABLE_NAME"
ARM64_RELEASE_DIR="$(dirname "$ARM64_BIN")"
X64_RELEASE_DIR="$(dirname "$X64_BIN")"
EXPECTED_RESOURCE_BUNDLE="${EXECUTABLE_NAME}_${TARGET_NAME}.bundle"

if [[ ! -f "$ARM64_BIN" ]]; then
  echo "arm64 binary not found: $ARM64_BIN" >&2
  exit 1
fi

if [[ ! -f "$X64_BIN" ]]; then
  echo "x86_64 binary not found: $X64_BIN" >&2
  exit 1
fi

echo "==> Creating universal binary"
lipo -create -output "$UNIVERSAL_BIN" "$ARM64_BIN" "$X64_BIN"

mkdir -p "$APP_BUNDLE_DIR/Contents/MacOS"
mkdir -p "$APP_BUNDLE_DIR/Contents/Resources"
cp "$UNIVERSAL_BIN" "$APP_BUNDLE_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_BUNDLE_DIR/Contents/MacOS/$EXECUTABLE_NAME"

# If SwiftPM generated a resource bundle, copy it into app resources.
if [[ -d "$ARM64_RELEASE_DIR/$EXPECTED_RESOURCE_BUNDLE" ]]; then
  if [[ ! -d "$X64_RELEASE_DIR/$EXPECTED_RESOURCE_BUNDLE" ]]; then
    echo "x86_64 build is missing resource bundle present in arm64 build: $EXPECTED_RESOURCE_BUNDLE" >&2
    exit 1
  fi
  cp -R "$ARM64_RELEASE_DIR/$EXPECTED_RESOURCE_BUNDLE" "$APP_BUNDLE_DIR/Contents/Resources/"
fi

cat > "$APP_BUNDLE_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Build a Finder app icon if source PNG exists.
SOURCE_APP_ICON="$ROOT_DIR/Sources/1132Fixer/Resources/AppIcon.png"
if [[ -f "$SOURCE_APP_ICON" ]]; then
  cp "$SOURCE_APP_ICON" "$APP_BUNDLE_DIR/Contents/Resources/AppIcon.png"
  ICONSET_DIR="$TEMP_BUILD_ROOT/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"
  sips -z 16 16 "$SOURCE_APP_ICON" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$SOURCE_APP_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$SOURCE_APP_ICON" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$SOURCE_APP_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$SOURCE_APP_ICON" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$SOURCE_APP_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$SOURCE_APP_ICON" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$SOURCE_APP_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$SOURCE_APP_ICON" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$SOURCE_APP_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE_DIR/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing app bundle ($SIGN_IDENTITY)"
codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE_DIR"
codesign --verify --strict --verbose=2 "$APP_BUNDLE_DIR"

echo "==> Creating DMG"
rm -f "$DMG_PATH"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_BUNDLE_DIR" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH"

echo "==> Signing DMG ($SIGN_IDENTITY)"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "==> Notarizing DMG"

  if [[ -z "$APPLE_API_KEY_ID" || -z "$APPLE_API_ISSUER_ID" ]]; then
    echo "Missing APPLE_API_KEY_ID or APPLE_API_ISSUER_ID for notarization." >&2
    exit 1
  fi

  KEY_FILE=""
  if [[ -n "$APPLE_API_KEY_PATH" ]]; then
    KEY_FILE="$APPLE_API_KEY_PATH"
  elif [[ -n "$APPLE_API_PRIVATE_KEY" ]]; then
    KEY_FILE="$(mktemp -t "AuthKey.XXXXXX.p8")"
    trap 'rm -f "$KEY_FILE"' EXIT
    printf '%s' "$APPLE_API_PRIVATE_KEY" > "$KEY_FILE"
  else
    echo "Provide APPLE_API_KEY_PATH or APPLE_API_PRIVATE_KEY for notarization." >&2
    exit 1
  fi

  xcrun notarytool submit "$DMG_PATH" \
    --key "$KEY_FILE" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait

  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_PATH"
fi

echo "==> Done"
echo "App: $APP_BUNDLE_DIR"
echo "DMG: $DMG_PATH"
echo "Architectures in binary:"
lipo -info "$APP_BUNDLE_DIR/Contents/MacOS/$EXECUTABLE_NAME"
