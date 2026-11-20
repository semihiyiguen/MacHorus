# Architecture

MacHorus is a single menu-bar app written in Swift 6 (strict concurrency) with AppKit and SwiftUI. It is built with SwiftPM and the Command Line Tools only; Xcode is not needed.

## Modules

| Target | Role | Depends on |
|---|---|---|
| `MacHorusCore` | Feature registry, settings, policy (configuration profiles), permissions overview, logging, app identity | – |
| `MacHorusMonitor` | Read-only measurements: CPU, memory, GPU, disk, network (per app via `nettop`/NetworkStatistics), VPN, temperatures and fans, battery, processes, health hints, widget layout model | Core |
| `MacHorusTools` | Things that act on request: keep awake, microphone mute, audio devices, sound per app (Core Audio process taps), clipboard history, network check, drives, printers, disk usage | Core, `CCups`, `CAtomics` |
| `MacHorus` | The app: status item, panel (SwiftUI), widgets, settings, alerts | all of the above |
| `CAtomics` | Lock-free relaxed atomics for the real-time audio thread (macOS 14 compatible) | – |
| `CCups` | Module map for libcups (print queue) | – |

Tests live in `Tests/` (Swift Testing), one target per library.

## Principles

1. **Measure only while someone looks.** Each widget declares the metrics it needs; the monitor samples only the union of the widgets on the visible page. With the panel closed, MacHorus costs about as much as an app that was never opened. Menu-bar values and alerts sample on their own, and pause while the screen is locked or asleep.
2. **No subprocess in a hot path.** Values come from Mach, sysctl, IOKit and Core Audio. `nettop` runs only while a per-app network list is on screen.
3. **Every feature can be switched off, and off costs nothing.** A feature is created when enabled and released when disabled (`FeatureRegistry`, `FeatureController`).
4. **Permissions only for the feature that needs them,** asked by macOS when that feature first needs one. Administrator rights, Full Disk Access, Accessibility and Screen Recording are never requested. See [PRIVACY.md](PRIVACY.md).
5. **Private APIs only behind adapters** in `MacHorusMonitor/PrivateAPI/`, each with a capability check, a public fallback and a policy switch (`DisabledPrivateAPIs`). See [ADMINISTRATION.md](ADMINISTRATION.md).
6. **Nothing leaves the Mac.** No account, no telemetry, no update check. The only network access is the network check, when the user starts it.
7. **Every value is verified** against a macOS tool (Activity Monitor formulas, `top`, `nettop`, `pmset`, `system_profiler` …). See [MEASUREMENTS.md](MEASUREMENTS.md) and `scripts/dev/verify-*.py`.

## Panel and widgets

The panel has four pages: Overview, Monitor, Tools and Settings, in a compact (360 pt) and an expanded (720 pt) width. Overview, Monitor and Tools are widget boards:

- A fixed grid (two columns compact, four expanded; rows of 96 pt), five sizes from 1×1 to 2×4 plus a 4×4 for long lists.
- Layouts per page and width are stored as JSON (`WidgetLayouts`), placed by `WidgetLayout.place` (first free cell that fits; tested with random layouts for overlaps).
- Drag and drop changes the order once on release (`ReorderEngine`); nothing moves while dragging.
- A widget whose content needs more room (sound) reports its height and grows downwards; widgets below move down.

## Settings and policy

- User settings live in `UserDefaults` (`app.machorus.MacHorus`), versioned by a schema number.
- Administrators can force features on or off and disable private APIs with a configuration profile or a plist in `/Library/Preferences` / `/Library/Managed Preferences` ([ADMINISTRATION.md](ADMINISTRATION.md)).

## Debugging without clicking

The app accepts launch arguments for reproducible checks, for example:

- `-debug.panelWindow overview|monitor|tools|settings` shows the panel in a normal window, `-debug.renderPanel <file.png>` renders it to a PNG and quits.
- `-panelExpanded YES|NO`, `-debug.appearance dark|light`, `-debug.defaultLayouts YES` (default layouts without touching saved ones).
- `-debug.demo YES` replaces app names, per-app network, audio device names and the computer name with neutral sample data (`Sources/MacHorus/Debug/DemoMode.swift`), for screenshots without personal data; all other values stay live.
- `MacHorus --print-diagnosis`, `--print-sensors`, `--print-updates`, `--print-ports`, `--benchmark-samplers [rounds] [name]`.

`debug.*` values are only honoured as launch arguments; persisted ones are removed at launch.
