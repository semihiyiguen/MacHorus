# Privacy and permissions

MacHorus works on the Mac it runs on and nowhere else:

- No account, no telemetry, no analytics, no crash reporting, no update check.
- Nothing about the Mac or the user is sent anywhere. The only network traffic is the network check, and only when you click it (see [Network connections](#network-connections)).
- No administrator rights: MacHorus never asks for an administrator password and installs no helper tool, daemon or kernel extension.
- Features that need a macOS permission ask for it only when they are actually used. If a permission is missing, only that feature stops working; everything else runs on.

## Permissions

### Requested only when you use the feature

| Permission | Feature | When macOS asks | Without it |
|---|---|---|---|
| **Notifications** | Alerts (`monitor.alerts`) | When the first alert is delivered as a notification, or when you click "Allow notifications" in Settings → Alerts | The eye in the menu bar still shows a warning badge and the overview lists the alert |
| **System Audio Recording Only** | Sound per App (`audio.mixer`) | The first time you change the volume of, or mute, a single app | Volume per app is unavailable; the box still shows which apps play sound or use a microphone |
| **Files and Folders** (Desktop, Documents, Downloads) | Disk → "Analyse" (largest folders and files in your home folder) | Once per folder, the first time you click "Analyse" | That folder is listed under "Not counted without access"; the rest is analysed |
| **Paste from other apps** (asked by recent macOS versions) | Clipboard history (`clipboard.history`) | When MacHorus first reads the clipboard, unless macOS is set to always allow it | The history stays empty |

Notes:

- **System Audio Recording** is needed because per-app volume uses a Core Audio process tap: the app's sound is routed through MacHorus and played back at the chosen level. MacHorus never records, stores or sends audio. A tap lives only as long as MacHorus runs; if MacHorus quits, every app gets its sound back. Apps left at 100 % are not tapped at all.
- **Open at login** needs no permission. MacHorus registers itself as the app's own login item (`SMAppService.mainApp`); macOS shows "Login item added" once. You can switch it off in MacHorus (Settings → Features → "Open at login") or in System Settings → General → Login Items.

### Never requested

| Permission | Why it is not needed |
|---|---|
| Administrator password | All values are read with user rights. Fan control, other users' processes and closed-lid operation are out of scope for that reason |
| Full Disk Access | Nothing reads protected locations. The disk usage view (largest folders in the home folder, on request) skips folders that would make macOS ask about other apps' data, Mail, Messages, Photos or iCloud Drive |
| Screen Recording | No feature captures the screen |
| Bluetooth | Accessory batteries come from the I/O Registry (`BatteryPercent`); device names are not read |
| Microphone | "Mute all microphones" changes device settings (mute switch or input volume) through Core Audio and records nothing |
| Location | The Wi-Fi signal is read without the network name (the name would require Location) |
| Accessibility, Input Monitoring | No current feature controls other apps or reads keystrokes. The clipboard shortcut uses `RegisterEventHotKey`, which needs neither |
| Camera, Calendars, Automation | No current feature uses them |

Full Disk Access, Screen Recording and Bluetooth are excluded in code: a feature that declares one of them cannot be registered.

### How permissions are checked

- Permission states are never read at launch. Settings → Privacy reads them while the page is visible.
- Merely querying Accessibility or Screen Recording adds the app to the list in System Settings, so those states are only read while an active feature needs them. Permissions MacHorus never uses are not read at all.
- Settings → Privacy lists which active feature uses which permission and links to the matching page in System Settings.

To reset every permission entry of MacHorus (macOS asks again on next use):

```bash
tccutil reset All app.machorus.MacHorus
```

## Private Apple interfaces

Four values use undocumented Apple interfaces. They need no permission, but they may change with a macOS update. MacHorus therefore uses them only under these rules:

- **Read-only and only what is needed.** `NetworkStatistics` also returns process names and addresses per connection; MacHorus reads only the byte counters. The SMC is only read, never written (no fan control).
- **Always with a fallback.** If an interface is missing or returns nonsense, MacHorus falls back to public sources or shows no value.
- **Always with a kill switch** for administrators: `DisabledPrivateAPIs` in the policy file (see [ADMINISTRATION.md](ADMINISTRATION.md)).

| Name | Used for | When disabled |
|---|---|---|
| `NetworkStatistics` | Upload and download totals: bytes per connection over Wi-Fi, wired and cellular | Interface counters are used instead. Behind a network filter or VPN client the download then shows "not measurable"; upload stays correct |
| `HIDSensors` (`IOHIDEventSystemClient`) | Temperatures of CPU, GPU, SSD and battery on Apple silicon | No temperatures on Apple silicon (fan speeds still come from the SMC if allowed) |
| `SMC` (`AppleSMC`) | Fan speeds; on Intel Macs also temperatures | No fan row; on Intel Macs no temperatures |
| `ProcessResponsibility` (libsystem) | Grouping helper processes under their app in the process list and in "who plays sound / uses a microphone" | Every process gets its own row |

GPU utilization comes from the public I/O Registry (`IOAccelerator` → `PerformanceStatistics`) and needs no kill switch.

## Network connections

MacHorus opens network connections only for the **network check**, and only when you click "Start check" (or run `MacHorus --network-check`). The feature can be switched off (`support.networkCheck`).

| Target | Purpose | Details |
|---|---|---|
| Router (default gateway), ICMP echo | Step "Router" | Local network only; up to three pings, 1 s each |
| System resolver (DNS), name `captive.apple.com` | Step "Name resolution" | Through `getaddrinfo`, i.e. the Mac's own DNS servers |
| `https://captive.apple.com/hotspot-detect.html` (GET) | Step "Internet"; detects Wi-Fi login pages | One request, at most 6 s, ephemeral session without cookies, cache or stored credentials. This is the same address macOS itself checks |

Nothing about the Mac or the user is included in these requests.

Everything else is local:

- Network rates per connection (`NetworkStatistics`) and per app (`/usr/bin/nettop`) read counters from the kernel; they open no connection.
- VPN service names come from `/usr/sbin/scutil --nc list`.
- Software updates are read from local files (`/Library/Managed Installs/InstallInfo.plist`, `/Library/Preferences/ManagedInstalls.plist`, `/Library/Preferences/com.apple.SoftwareUpdate.plist`). From Munki's preferences only the date of the last check is used; the repository address and client identifier are not. MacHorus downloads nothing; "Open Munki" / "Open Software Update" only opens the app that installs updates.
- There is no built-in updater.

Settings → Privacy shows a short statement of this, depending on whether the network check is on.

## What is stored

### Settings

Settings are stored with `UserDefaults` in `~/Library/Preferences/app.machorus.MacHorus.plist`, only on this Mac:

- which features are on, and the settings schema version
- widget layouts, panel width, appearance and language
- menu bar values, alert rules and whether alerts are sent as notifications
- dismissed status items on the overview
- per-app volume levels (keyed by the app's bundle identifier)
- microphones muted by MacHorus (device UID and the volume to restore), so a mute never outlives the app, even after a crash
- keep-awake display choice, clipboard memory limit and clipboard shortcut
- whether "Open at login" has been decided

Updates never overwrite these settings. Uninstalling the app leaves the file in place; delete it to remove all settings.

### Clipboard history

- Kept **only in memory**, never written to disk. It starts empty at every launch, so a restart or quitting MacHorus clears it. Pinned entries are in memory too.
- Never recorded: copies made while a known password manager is in front (for example Apple Passwords, Keychain Access, 1Password, Bitwarden, KeePassXC), and copies the source app marks as concealed, transient or auto-generated ([nspasteboard.org](http://nspasteboard.org) markers). The card says why a copy was skipped.
- App-private formats are not kept; only text, rich text, HTML, images, files and links.
- Switching the feature off forgets the whole history immediately.
- Nothing is read from the clipboard while the screen is locked or asleep.
- Text and QR-code recognition in images run locally and never open anything.

### Logs

MacHorus writes to the macOS unified log (subsystem `app.machorus.MacHorus`), which stays on the Mac. Log entries contain no clipboard contents.

### Diagnosis

`MacHorus --print-diagnosis` prints a diagnosis to the terminal only when you run it. It contains no serial number, computer name, network addresses or app names (see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)).
