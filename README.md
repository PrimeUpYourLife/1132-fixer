# 1132 Fixer

<img src="Sources/1132Fixer/Resources/AppIcon.png" width="128" alt="1132 Fixer app icon">

Minimal macOS app with one button:

- `Start Zoom`: kills Zoom, clears Zoom local data/cache/preferences/log state, requests admin access to flush system DNS caches, and relaunches Zoom

The app runs local recovery commands for Error 1132 and performs DNS cache reset via AppleScript (`do shell script ... with administrator privileges`) so macOS can present a native admin-password prompt.

## Updates

On launch, the app checks the GitHub Releases `latest` endpoint and prompts if a newer version is available.

## License and Risk

This project is licensed under the terms in `LICENSE`.

The software is provided "as is" with no warranty. Installing and using it is
at your own risk, and users accept responsibility for any impact on their
systems or data.
