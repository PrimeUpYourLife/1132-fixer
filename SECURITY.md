# Security Policy

## Supported Versions

Only the **latest release** of 1132 Fixer receives security updates.

Users are strongly encouraged to always download the newest version from the official releases page.

| Version | Supported |
| ------- | --------- |
| Latest  | ✅ |
| Older versions | ❌ |

Security fixes will be released as soon as possible in a new version.

## Release Integrity

Every released `.dmg` is signed with a Developer ID Application certificate,
built with the hardened runtime, notarized by Apple, and has the notarization
ticket stapled to it.

This is enforced, not just intended:

- `scripts/build-universal-dmg.sh` notarizes, staples, and then **verifies the
  finished image** before it will report success. Notarization cannot be
  skipped on a release build; the local-development opt-out (`NOTARIZE=0`) is
  refused in CI and renames its output `UNNOTARIZED-DO-NOT-DISTRIBUTE`.
- The `Release notarization` workflow re-verifies the **published** asset on a
  macOS runner with `stapler validate`, `codesign --verify` and `spctl
  --assess`, plus a portable ticket parser.
- Both checks fail closed. An unverifiable artifact is treated as
  un-notarized.

You can verify a download yourself:

```sh
xcrun stapler validate "1132 Fixer-v<version>-universal.dmg"
python3 scripts/verify-notarization.py "1132 Fixer-v<version>-universal.dmg"
```

The second command needs no macOS tooling and works on any platform. It reports
the artifact's SHA-256 and the code-directory hash that Apple's ticket certifies.

## Reporting a Vulnerability

If you discover a security vulnerability in **1132 Fixer**, please report it responsibly.

Do **not** open a public GitHub issue for security vulnerabilities.

Instead, open a **private security advisory** on GitHub

Please include:

- A description of the vulnerability
- Steps to reproduce the issue
- The affected version
- Any proof-of-concept or screenshots (if applicable)

## Response Process

After a vulnerability report is received:

1. You will receive an acknowledgement within **72 hours**
2. The issue will be investigated and reproduced
3. If confirmed, a fix will be prepared and released
4. Credit may be given to the reporter if they wish

Critical vulnerabilities will be prioritized and fixed as quickly as possible.

## Responsible Disclosure

Please allow reasonable time for the issue to be resolved before publicly disclosing it.

Public disclosure before a fix is available may put users at risk.
