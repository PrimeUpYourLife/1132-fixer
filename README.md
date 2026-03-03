# 1132 Fixer

## [Download the latest release here](https://github.com/PrimeUpYourLife/1132-fixer/releases/latest)

<img src="Sources/1132Fixer/Resources/AppIcon.png" width="128" alt="1132 Fixer app icon">

![GitHub Release](https://img.shields.io/github/v/release/PrimeUpYourLife/1132-fixer?style=for-the-badge) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/PrimeUpYourLife/1132-fixer/total?style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-silicone-yellow?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-intel-purple?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-universal-green?logo=apple&style=for-the-badge)


Minimal macOS app with two actions:

- `Start Zoom`: spoofs a random MAC address on the active Wi-Fi/Ethernet interface, automatically disconnects/reconnects that network service, kills Zoom, clears Zoom local data/cache/preferences/log state, requests admin access to flush system DNS caches, and relaunches Zoom
- `Report a Bug`: opens a small form for optional email + message, then sends diagnostics (app version, OS, architecture, timestamp, and the latest 200 log lines) to the bug report API

The app runs local recovery commands for Error 1132 and performs network interface MAC spoofing/reconnect plus DNS cache reset via AppleScript (`do shell script ... with administrator privileges`) so macOS can present native admin-password prompts.

Recent compatibility update: MAC address changes now try `ifconfig ... lladdr ...` first and fall back to `ifconfig ... ether ...` to avoid failures seen on newer macOS versions (including Sequoia).
Current reconnect flow applies the MAC change before toggling the network service off/on to avoid `ifconfig ... Network is down` failures reported on some Ethernet setups.
Current reconnect flow brings the interface down, applies the MAC, brings it back up, then toggles the network service off/on; if that fails, it falls back to a direct MAC-change + reconnect order for compatibility.

## Updates

On launch, the app checks the GitHub Releases `latest` endpoint and prompts if a newer version is available.

## Bug Reporting

`Report a Bug` sends a POST request to:
- `https://1132-bug-report-production.up.railway.app/api/bug-report`

Payload fields:
- `Title`
- `Email` (optional)
- `Message`
- `System Info`
- `Recent Logs`

If API submission fails, the app logs the error in the Activity Log.

Configuration variables are loaded from runtime env first, then bundled resource files:
- `FIXER_BUG_REPORT_ENDPOINT`
- `FIXER_BUG_REPORT_TOKEN`

For local run:

```bash
FIXER_BUG_REPORT_ENDPOINT=https://1132-bug-report-production.up.railway.app/api/bug-report \
FIXER_BUG_REPORT_TOKEN=your_token_here \
swift run
```

## License and Risk

This project is licensed under the terms in `LICENSE`.

The software is provided "as is" with no warranty. Installing and using it is
at your own risk, and users accept responsibility for any impact on their
systems, network connectivity, or data.
