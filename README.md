# 1132 Fixer

Minimal macOS SwiftUI app with two buttons:

- `Spoof MAC Address`: runs your MAC spoof script (prompts for admin password)
- `Start Zoom`: starts Zoom with your `sandbox-exec` policy in detached mode (non-blocking UI)

The MAC spoof flow disconnects Wi-Fi, tries multiple valid locally administered MAC candidates (including one derived from the current hardware prefix), refreshes network hardware, and logs the final MAC for verification.

## Run

```bash
swift run
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
