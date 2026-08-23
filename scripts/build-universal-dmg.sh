#!/usr/bin/env bash
set -euo pipefail

APP_NAME="1132 Fixer"
EXECUTABLE_NAME="1132 Fixer"
TARGET_NAME="1132Fixer"
# Must match CFBundleIdentifier in Sources/1132Fixer/Info.plist. Overridable via env.
BUNDLE_ID="${BUNDLE_ID:-com.1132fixer.1132-Fixer}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
APPLE_DEVELOPER_FILE="${APPLE_DEVELOPER_FILE:-$ROOT_DIR/apple-developer.txt}"
MIN_MACOS_FILE="$ROOT_DIR/MIN_MACOS_VERSION"
BUG_REPORT_ENDPOINT_RESOURCE_FILE="$ROOT_DIR/Sources/1132Fixer/Resources/FIXER_BUG_REPORT_ENDPOINT"
BUG_REPORT_TOKEN_RESOURCE_FILE="$ROOT_DIR/Sources/1132Fixer/Resources/FIXER_BUG_REPORT_TOKEN"
DIST_DIR="$ROOT_DIR/dist"
ENTITLEMENTS_FILE="$ROOT_DIR/Sources/1132Fixer/1132Fixer.entitlements"
TEMP_BUILD_ROOT="$ROOT_DIR/.build/universal"
ARM64_BUILD_DIR="$TEMP_BUILD_ROOT/arm64"
X64_BUILD_DIR="$TEMP_BUILD_ROOT/x86_64"
UNIVERSAL_DIR="$TEMP_BUILD_ROOT/merged"
APP_BUNDLE_DIR="$DIST_DIR/$APP_NAME.app"
APP_VERSION="${APP_VERSION:-}"
APP_BUILD="${APP_BUILD:-1}"
FIXER_BUG_REPORT_ENDPOINT="${FIXER_BUG_REPORT_ENDPOINT:-}"
FIXER_BUG_REPORT_TOKEN="${FIXER_BUG_REPORT_TOKEN:-}"
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

# Required for distribution: Developer ID Application identity.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

# Notarization is mandatory for anything that leaves this machine.
#
# NOTARIZE=0 is a LOCAL-DEVELOPMENT escape hatch only. It is refused outright on
# the release path (CI, or RELEASE_BUILD=1), and when it is used the resulting
# image is renamed so it can never be mistaken for, or uploaded as, a release
# asset. Only the exact values "1" and "0" are accepted -- see the policy gate
# below. Anything else is a hard error rather than a silent skip.
NOTARIZE="${NOTARIZE:-1}"

# Set RELEASE_BUILD=1 for any build whose output may be published.
RELEASE_BUILD="${RELEASE_BUILD:-0}"

APPLE_ID="${APPLE_ID:-}"
APPLE_PASSWORD="${APPLE_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_CERTIFICATE="${APPLE_CERTIFICATE:-}"
APPLE_CERTIFICATE_PASSWORD="${APPLE_CERTIFICATE_PASSWORD:-}"

if [[ -f "$APPLE_DEVELOPER_FILE" ]]; then
  echo "==> Loading Apple developer settings from $APPLE_DEVELOPER_FILE"
  # apple-developer.txt is stored as simple KEY=VALUE assignments.
  set -a
  # shellcheck disable=SC1090
  source "$APPLE_DEVELOPER_FILE"
  set +a
fi

# ---------------------------------------------------------------------------
# Notarization policy gate
#
# Runs after $APPLE_DEVELOPER_FILE is sourced, because that file can also set
# NOTARIZE, and before anything is built, signed or deleted. Fails closed: an
# unrecognised value is an error, never a skip.
# ---------------------------------------------------------------------------
case "$NOTARIZE" in
  1|0) ;;
  *)
    echo "NOTARIZE_INVALID: NOTARIZE must be exactly '1' or '0' (got '$NOTARIZE')." >&2
    echo "Refusing to guess. An unrecognised value used to skip notarization silently." >&2
    exit 1
    ;;
esac

if [[ "$NOTARIZE" != "1" ]]; then
  if [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" || "$RELEASE_BUILD" == "1" ]]; then
    echo "NOTARIZE_DISABLED_ON_RELEASE_PATH: notarization cannot be skipped on a release or CI build." >&2
    exit 1
  fi

  DMG_PATH="$DIST_DIR/$APP_NAME-v$APP_VERSION-universal-UNNOTARIZED-DO-NOT-DISTRIBUTE.dmg"
  echo "############################################################" >&2
  echo "## NOTARIZATION DISABLED -- LOCAL DEVELOPMENT BUILD ONLY   ##" >&2
  echo "## Output is named UNNOTARIZED-DO-NOT-DISTRIBUTE.          ##" >&2
  echo "## Gatekeeper will reject it. Never publish this image.    ##" >&2
  echo "############################################################" >&2
fi

decode_base64_to_file() {
  local destination="$1"

  if printf '%s' "$APPLE_CERTIFICATE" | base64 --decode > "$destination" 2>/dev/null; then
    return 0
  fi

  if printf '%s' "$APPLE_CERTIFICATE" | base64 -D > "$destination" 2>/dev/null; then
    return 0
  fi

  echo "Failed to decode APPLE_CERTIFICATE." >&2
  exit 1
}

BUG_REPORT_ENDPOINT_BACKUP_FILE=""
BUG_REPORT_TOKEN_BACKUP_FILE=""
CERTIFICATE_P12_FILE=""
KEYCHAIN_PATH=""
KEYCHAIN_PASSWORD=""
SIGN_IDENTITY_HASH=""
ORIGINAL_KEYCHAINS=()
cleanup_bug_report_resources() {
  if [[ -n "$BUG_REPORT_ENDPOINT_BACKUP_FILE" && -f "$BUG_REPORT_ENDPOINT_BACKUP_FILE" ]]; then
    cp "$BUG_REPORT_ENDPOINT_BACKUP_FILE" "$BUG_REPORT_ENDPOINT_RESOURCE_FILE"
    rm -f "$BUG_REPORT_ENDPOINT_BACKUP_FILE"
  fi
  if [[ -n "$BUG_REPORT_TOKEN_BACKUP_FILE" && -f "$BUG_REPORT_TOKEN_BACKUP_FILE" ]]; then
    cp "$BUG_REPORT_TOKEN_BACKUP_FILE" "$BUG_REPORT_TOKEN_RESOURCE_FILE"
    rm -f "$BUG_REPORT_TOKEN_BACKUP_FILE"
  fi
  if [[ -n "$CERTIFICATE_P12_FILE" && -f "$CERTIFICATE_P12_FILE" ]]; then
    rm -f "$CERTIFICATE_P12_FILE"
  fi
  if [[ "${#ORIGINAL_KEYCHAINS[@]}" -gt 0 ]]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  fi
  if [[ -n "$KEYCHAIN_PATH" && -f "$KEYCHAIN_PATH" ]]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi
}
trap cleanup_bug_report_resources EXIT

if [[ -f "$BUG_REPORT_ENDPOINT_RESOURCE_FILE" ]]; then
  BUG_REPORT_ENDPOINT_BACKUP_FILE="$(mktemp -t fixer-bug-report-endpoint-backup.XXXXXX)"
  cp "$BUG_REPORT_ENDPOINT_RESOURCE_FILE" "$BUG_REPORT_ENDPOINT_BACKUP_FILE"
fi

if [[ -f "$BUG_REPORT_TOKEN_RESOURCE_FILE" ]]; then
  BUG_REPORT_TOKEN_BACKUP_FILE="$(mktemp -t fixer-bug-report-token-backup.XXXXXX)"
  cp "$BUG_REPORT_TOKEN_RESOURCE_FILE" "$BUG_REPORT_TOKEN_BACKUP_FILE"
fi

if [[ -n "$FIXER_BUG_REPORT_ENDPOINT" ]]; then
  echo "==> Embedding FIXER_BUG_REPORT_ENDPOINT into app resources for this build"
  printf '%s\n' "$FIXER_BUG_REPORT_ENDPOINT" > "$BUG_REPORT_ENDPOINT_RESOURCE_FILE"
fi

if [[ -n "$FIXER_BUG_REPORT_TOKEN" ]]; then
  echo "==> Embedding FIXER_BUG_REPORT_TOKEN into app resources for this build"
  printf '%s\n' "$FIXER_BUG_REPORT_TOKEN" > "$BUG_REPORT_TOKEN_RESOURCE_FILE"
fi

rm -rf "$DIST_DIR" "$TEMP_BUILD_ROOT"
mkdir -p "$DIST_DIR" "$UNIVERSAL_DIR"

if [[ -z "$SIGN_IDENTITY" ]]; then
  if [[ -z "$APPLE_CERTIFICATE" || -z "$APPLE_CERTIFICATE_PASSWORD" ]]; then
    echo "Missing signing configuration. Set SIGN_IDENTITY or provide APPLE_CERTIFICATE and APPLE_CERTIFICATE_PASSWORD in $APPLE_DEVELOPER_FILE." >&2
    exit 1
  fi

  CERTIFICATE_P12_FILE="$(mktemp -t fixer-signing-certificate.XXXXXX.p12)"
  decode_base64_to_file "$CERTIFICATE_P12_FILE"

  KEYCHAIN_PATH="$TEMP_BUILD_ROOT/build-signing.keychain-db"
  KEYCHAIN_PASSWORD="$(uuidgen | tr -d '-')$(uuidgen | tr -d '-')"
  KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:0:32}"

  echo "==> Importing signing certificate into temporary keychain"
  rm -f "$KEYCHAIN_PATH"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  while IFS= read -r existing_keychain; do
    existing_keychain="${existing_keychain//\"/}"
    if [[ -n "$existing_keychain" ]]; then
      ORIGINAL_KEYCHAINS+=("$existing_keychain")
    fi
  done < <(security list-keychains -d user)
  security import "$CERTIFICATE_P12_FILE" \
    -f pkcs12 \
    -k "$KEYCHAIN_PATH" \
    -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null
  security list-keychains -d user -s "$KEYCHAIN_PATH" "${ORIGINAL_KEYCHAINS[@]}" >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null

  SIGN_IDENTITY_HASH="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | awk '/Developer ID Application: / { print $2; exit }')"
  SIGN_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | awk -F'"' '/Developer ID Application: / { print $2; exit }')"
  if [[ -z "$SIGN_IDENTITY_HASH" ]]; then
    echo "Unable to locate a Developer ID Application identity hash in the imported certificate." >&2
    exit 1
  fi
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Unable to locate a Developer ID Application identity in the imported certificate." >&2
    exit 1
  fi
fi

codesign_args=()
if [[ -n "$KEYCHAIN_PATH" ]]; then
  codesign_args+=(--keychain "$KEYCHAIN_PATH")
fi

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

# Use the project's Info.plist as the authoritative source, then patch in
# build-time values (version, bundle ID, executable name, etc.).
SOURCE_INFO_PLIST="$ROOT_DIR/Sources/1132Fixer/Info.plist"
if [[ ! -f "$SOURCE_INFO_PLIST" ]]; then
  echo "Missing Info.plist: $SOURCE_INFO_PLIST" >&2
  exit 1
fi
cp "$SOURCE_INFO_PLIST" "$APP_BUNDLE_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE_NAME" "$APP_BUNDLE_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$APP_BUNDLE_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_MACOS" "$APP_BUNDLE_DIR/Contents/Info.plist"

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

if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
  echo "Missing entitlements file: $ENTITLEMENTS_FILE" >&2
  exit 1
fi

echo "==> Signing app bundle ($SIGN_IDENTITY)"
codesign --force --deep --options runtime --timestamp --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS_FILE" --sign "${SIGN_IDENTITY_HASH:-$SIGN_IDENTITY}" "${codesign_args[@]}" "$APP_BUNDLE_DIR"
codesign --verify --strict --verbose=2 "$APP_BUNDLE_DIR"
echo "==> Entitlements embedded in signature:"
codesign -d --entitlements :- "$APP_BUNDLE_DIR" 2>/dev/null | grep -iE 'camera|audio-input|apple-events' || echo "WARNING: camera/mic entitlements not found after signing"

echo "==> Creating DMG"
rm -f "$DMG_PATH"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_BUNDLE_DIR" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH"

echo "==> Signing DMG ($SIGN_IDENTITY)"
codesign --force --timestamp --sign "${SIGN_IDENTITY_HASH:-$SIGN_IDENTITY}" "${codesign_args[@]}" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "==> Notarizing DMG"

  if [[ -z "$APPLE_ID" || -z "$APPLE_PASSWORD" || -z "$APPLE_TEAM_ID" ]]; then
    echo "Missing APPLE_ID, APPLE_PASSWORD, or APPLE_TEAM_ID for notarization." >&2
    exit 1
  fi

  # notarytool writes its transcript to a file that is never echoed: it can
  # contain submission metadata and local paths. Only the status word is
  # printed. `notarytool submit --wait` is not reliably non-zero on an
  # `Invalid` result, so the status is parsed and required to be `Accepted`.
  NOTARY_TRANSCRIPT="$TEMP_BUILD_ROOT/notarytool-submit.log"
  set +e
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait > "$NOTARY_TRANSCRIPT" 2>&1
  NOTARY_EXIT=$?
  set -e

  NOTARY_STATUS="$(awk -F': *' '/^[[:space:]]*status:/ { print $2 }' "$NOTARY_TRANSCRIPT" | tail -n 1 | tr -d '[:space:]')"
  echo "==> Notary result: status=${NOTARY_STATUS:-<none>} exit=$NOTARY_EXIT"
  echo "    (full transcript withheld from the log: $NOTARY_TRANSCRIPT)"

  if [[ "$NOTARY_EXIT" -ne 0 || "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "NOTARIZATION_NOT_ACCEPTED: notary service did not return Accepted." >&2
    echo "Inspect $NOTARY_TRANSCRIPT manually. Nothing is published from this build." >&2
    exit 1
  fi

  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_PATH"

  # Prove the ticket from the finished artifact, not from the fact that the
  # commands above exited 0. This is the same check CI runs on the published
  # asset; running it here blocks a bad image BEFORE it can be uploaded.
  echo "==> Verifying stapled ticket on the finished DMG"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "VERIFIER_UNAVAILABLE: python3 is required to verify the stapled ticket." >&2
    echo "unknown is not notarized -- refusing to declare this build releasable." >&2
    exit 1
  fi
  python3 "$ROOT_DIR/scripts/verify-notarization.py" "$DMG_PATH"
fi

echo "==> Done"
echo "App: $APP_BUNDLE_DIR"
echo "DMG: $DMG_PATH"
echo "Architectures in binary:"
lipo -info "$APP_BUNDLE_DIR/Contents/MacOS/$EXECUTABLE_NAME"
