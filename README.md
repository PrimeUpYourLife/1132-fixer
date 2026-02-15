# 1132 Fixer

Minimal macOS SwiftUI app with two buttons:

- `Spoof MAC Address`: runs your MAC spoof script (prompts for admin password)
- `Start Zoom`: starts Zoom with your `sandbox-exec` policy in detached mode (non-blocking UI)

The MAC spoof flow disconnects Wi-Fi, tries multiple valid locally administered MAC candidates (including one derived from the current hardware prefix), refreshes network hardware, and logs the final MAC for verification.

## Run

```bash
swift run
```

## Build Universal DMG (Local)

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_API_KEY_ID="ABC123XYZ" \
APPLE_API_ISSUER_ID="00000000-0000-0000-0000-000000000000" \
APPLE_API_KEY_PATH="$HOME/.private_keys/AuthKey_ABC123XYZ.p8" \
./scripts/build-universal-dmg.sh
```

Artifacts:

- app bundle: `dist/1132 Fixer.app`
- universal DMG: `dist/1132 Fixer-universal.dmg`

Alternative: provide key content directly instead of `APPLE_API_KEY_PATH`:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_API_KEY_ID="ABC123XYZ" \
APPLE_API_ISSUER_ID="00000000-0000-0000-0000-000000000000" \
APPLE_API_PRIVATE_KEY="$(cat "$HOME/.private_keys/AuthKey_ABC123XYZ.p8")" \
./scripts/build-universal-dmg.sh
```

Optional: skip notarization (for local testing only):

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARIZE=0 ./scripts/build-universal-dmg.sh
```

## License and Risk

This project is licensed under the terms in `LICENSE`.

The software is provided "as is" with no warranty. Installing and using it is
at your own risk, and users accept responsibility for any impact on their
systems or data.

## GitHub Release Automation

A GitHub Action at `.github/workflows/release-macos.yml` runs when a PR to `main` is merged. It:

- builds release binaries for Apple Silicon (`arm64`) and Intel (`x86_64`)
- signs each binary with Developer ID
- packages each binary into a `.dmg`
- notarizes and staples each `.dmg` with Apple notary service
- creates a GitHub Release and uploads both `.dmg` files

Required repository secrets:

- `APPLE_SIGNING_CERT_P12_BASE64` (base64-encoded Developer ID Application cert `.p12`)
- `APPLE_SIGNING_CERT_PASSWORD`
- `APPLE_DEVELOPER_ID_APPLICATION` (certificate common name, e.g. `Developer ID Application: Example, Inc. (TEAMID)`)
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_PRIVATE_KEY` (contents of `AuthKey_<KEYID>.p8`)
