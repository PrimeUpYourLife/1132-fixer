# 1132 Fixer

## [Download the latest release here](https://github.com/PrimeUpYourLife/1132-fixer/releases/latest)

<img src="Sources/1132Fixer/Resources/AppIcon.png" width="128" alt="1132 Fixer app icon">

![GitHub Release](https://img.shields.io/github/v/release/PrimeUpYourLife/1132-fixer?style=for-the-badge) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/PrimeUpYourLife/1132-fixer/total?style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-silicone-yellow?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-intel-purple?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-universal-green?logo=apple&style=for-the-badge)

## Minimal macOS app with two actions

- `Start Zoom`: closes Zoom if it is running, stops immediately if a VPN interface is active, spoofs a random MAC address on the active Wi-Fi/Ethernet interface, automatically disconnects/reconnects that network service, clears Zoom local data/cache/preferences/log state, requests admin access to flush system DNS caches, briefly bootstraps Zoom in a restricted sandbox to regenerate identity data, then relaunches Zoom normally so camera/video devices continue working
- `Report a Bug`: opens a small form for optional email + message, then sends diagnostics (app version, OS, architecture, timestamp, and the latest 200 log lines) to the bug report API

The app runs local recovery commands for Error 1132 and performs network interface MAC spoofing/reconnect plus DNS cache reset via AppleScript (`do shell script ... with administrator privileges`) so macOS can present native admin-password prompts.

## Updates

On launch, the app checks the GitHub Releases `latest` endpoint and prompts if a newer version is available.

## License and Risk

This project is licensed under the terms in `LICENSE`.

The software is provided "as is" with no warranty. Installing and using it is
at your own risk, and users accept responsibility for any impact on their
systems, network connectivity, or data.
