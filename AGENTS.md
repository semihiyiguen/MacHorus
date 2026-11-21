# AGENTS.md – guide for AI coding agents

MacHorus is an open-source (GPL-3.0-or-later) macOS menu-bar app: a system monitor plus everyday tools (sound per app, microphone mute, clipboard history, keep awake, network check, drives, printers). It is built to be **light, private and safe**: no administrator rights, no account, no telemetry, nothing sent. Read [README.md](README.md) for what it does and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how.

## Facts for a quick review

- Language: Swift 6 with strict concurrency; AppKit + SwiftUI; SwiftPM. No third-party dependencies.
- Network: the only outgoing request is `https://captive.apple.com/hotspot-detect.html` in `Sources/MacHorusTools/NetworkCheck.swift`, started by the user's click. There is no other `URLSession` use.
- Permissions: declared per feature in `Sources/MacHorusCore/Features/FeatureModule.swift`; macOS asks only when a feature first needs one (details in [docs/PRIVACY.md](docs/PRIVACY.md)). Never requested: admin rights, Full Disk Access, Accessibility, Screen Recording.
- Private APIs: read-only, only in `Sources/MacHorusMonitor/PrivateAPI/` (NetworkStatistics, HID temperature sensors, SMC read, process responsibility), each with a capability check, a public fallback and a policy switch.
- Storage: settings in `UserDefaults`; clipboard history in memory only.
- Some approaches (SMC parameter layout, process taps for per-app volume, responsible-process grouping) follow the GPL-3.0 project [Vorssaint utils](https://github.com/vorssaint/vorssaint-utils); the source comments say where.

## Build and verify

```bash
make build    # debug build, fails on any warning
make test     # Swift Testing
make lint     # swift-format (strict) + localization check (en and de keys must match)
make check    # lint + build + tests + Thread and Address Sanitizer
make run      # build/MacHorus.app, then open it
```

Only the Command Line Tools are needed; the Makefile pins `SDKROOT` to `MacOSX26.sdk`. Call `swift build` / `swift test` through `make`, not directly.

## Rules for changes

1. Zero warnings; strict concurrency; `make check` green.
2. No new network access, telemetry, account or permission without an issue that discusses it.
3. No subprocess and no polling in a hot path; measure only what is on screen (see the architecture doc). New cards are measured for CPU cost before they are merged.
4. Private APIs only behind an adapter in `PrivateAPI/` with a fallback and a `PrivateAPI` policy case.
5. Every displayed value is verified against a macOS tool (`scripts/dev/verify-monitor.py`, `scripts/dev/verify-tools.py`).
6. UI text: English source in `Resources/en.lproj/Localizable.strings`, German translation in `Resources/de.lproj`. `.strings`, not `.xcstrings`; no `#Preview` (no Xcode).
7. Every source file keeps its SPDX header: `// SPDX-License-Identifier: GPL-3.0-or-later`.
8. Code, comments, commit messages and documentation in English.
9. Never commit secrets, signing material, personal data or private hostnames. The pre-commit hook (`scripts/install-hooks.sh`) checks staged changes against a local, git-ignored pattern list.
10. No animated transitions on values that refresh (`.contentTransition(.numericText())`, implicit `.animation` on live values): SwiftUI draws them on the CPU every frame; it cost up to 15% CPU with the panel open.
11. Tests must not depend on a specific macOS version or on timing of a shared machine.

## Useful launch arguments

`-debug.panelWindow <overview|monitor|tools|settings>` shows the panel in a window; add `-debug.renderPanel <file.png>` to render it and quit (works with a locked screen). `-panelExpanded YES|NO`, `-debug.appearance dark|light`, `-debug.defaultLayouts YES`. Never test the clipboard with `pbcopy` (it overwrites the user's clipboard); use `-debug.clipboardName <name>`.
