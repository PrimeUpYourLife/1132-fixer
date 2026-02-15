# AGENTS.md

## Project
- Name: `1132 Fixer`
- Type: macOS SwiftUI executable (Swift Package Manager)
- Minimum platform: `macOS 13`

## Repository Layout
- `Package.swift`: package definition and executable target config
- `Sources/1132Fixer/1132FixerApp.swift`: app entry point
- `Sources/1132Fixer/ContentView.swift`: UI + command execution logic
- `Sources/1132Fixer/Resources/AppIcon.png`: app icon resource

## Development Commands
- Run app: `swift run`
- Debug build: `swift build`
- Release build: `swift build -c release`
- Release binary: `.build/release/1132 Fixer`

## Code Guidelines
- Keep code compatible with Swift 5.9 and macOS 13 APIs.
- Prefer small, focused changes over broad refactors.
- Preserve existing behavior unless the task explicitly requests behavior changes.
- Keep UI changes in SwiftUI and follow existing visual/component patterns.

## Safety Notes
- The app executes shell commands that can require admin privileges (`osascript` + `sudo`) and launch Zoom with `sandbox-exec`.
- Treat command/script edits as high impact; verify quoting and escaping carefully.
- Do not weaken or remove guardrails in scripts unless explicitly requested.

## Validation
- After edits, run at least: `swift build`
- If UI or runtime behavior changed, also run: `swift run` and verify no immediate startup errors.

## Agent Workflow
- Read this file before making changes.
- Prefer minimal diffs and keep unrelated files untouched.
- Document notable behavior or command changes in `README.md` when relevant.

