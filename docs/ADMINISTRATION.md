# Administration

Administrators can decide which MacHorus features are always on or always off on a Mac, and switch off the private Apple interfaces MacHorus uses. A policy overrides the user's choice; locked features cannot be changed in Settings → Features.

## Policy files

At launch MacHorus reads every file that exists at these paths and merges them:

| Path | Typical source |
|---|---|
| `/Library/Preferences/app.machorus.MacHorus.plist` | Package, script or software deployment tool |
| `/Library/Managed Preferences/app.machorus.MacHorus.plist` | Configuration profile (MDM) |
| `/Library/Managed Preferences/<user>/app.machorus.MacHorus.plist` | Configuration profile (MDM), per user |

**Trust rule:** a file counts only if it is **owned by root** and **not writable by group or others** (for example `root:wheel`, mode `644`). Otherwise it is ignored and an error is logged. This prevents users from unlocking features themselves.

Changes take effect at the next launch of MacHorus.

### Precedence

1. All trusted files are merged: the lists of all files are combined (union).
2. `DisabledFeatures` wins over `ForcedEnabledFeatures` and over the user's choice.
3. `ForcedEnabledFeatures` wins over the user's choice.
4. Everything else follows the user's settings in `~/Library/Preferences/app.machorus.MacHorus.plist`.

## Keys

| Key | Type | Effect |
|---|---|---|
| `ForcedEnabledFeatures` | Array of strings | These features are always on |
| `DisabledFeatures` | Array of strings | These features are always off. **Takes precedence** over `ForcedEnabledFeatures` and the user's choice |
| `DisabledPrivateAPIs` | Array of strings | Switches off private Apple interfaces. Values: `NetworkStatistics`, `HIDSensors`, `SMC`, `ProcessResponsibility` |

- Unknown feature IDs and interface names are ignored.
- Values of the wrong type are ignored instead of discarding the whole file.
- The policy can only switch a private interface off, never on.

## Example

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ForcedEnabledFeatures</key>
	<array>
		<string>monitor.alerts</string>
	</array>
	<key>DisabledFeatures</key>
	<array>
		<string>clipboard.history</string>
	</array>
	<key>DisabledPrivateAPIs</key>
	<array>
		<string>NetworkStatistics</string>
		<string>SMC</string>
	</array>
</dict>
</plist>
```

Installing it by hand (or from a package's `postinstall`):

```bash
sudo install -o root -g wheel -m 644 policy.plist /Library/Preferences/app.machorus.MacHorus.plist
```

Check which files were loaded or rejected (reading the log may require an administrator account):

```bash
log show --last 5m --predicate 'subsystem == "app.machorus.MacHorus" AND category == "policy"'
```

## Feature IDs

Feature IDs are stable and are never renamed. All features below are on by default for new users.

| Feature ID | Feature | Permission |
|---|---|---|
| `monitor.system` | System monitor: CPU, GPU, memory, network, disk, battery, temperatures and processes (including quitting the user's own processes) | – |
| `monitor.menubar` | Values next to the eye in the menu bar | – |
| `monitor.alerts` | Alerts: warning badge on the eye, entry on the overview, optional notifications | Notifications (optional) |
| `display.keepAwake` | Keep the Mac (and optionally the display) awake | – |
| `audio.micMute` | Mute all microphones | – |
| `audio.mixer` | Sound per app: volume and mute for single apps | System Audio Recording, asked at first use |
| `audio.devices` | Choose sound output and input | – |
| `clipboard.history` | Clipboard history, in memory only | macOS "paste from other apps" prompt on recent versions |
| `support.updates` | Pending Munki and macOS updates, read from local files | – |
| `support.networkCheck` | Network check (the only feature that goes online, on click) | – |
| `tools.ports` | Open TCP ports of the user's own apps, with quit | – |
| `tools.drives` | External drives, with eject | – |
| `tools.hardware` | Connected devices: displays, power adapter, USB devices, accessory batteries | – |
| `tools.printers` | Printers and the user's print jobs, with cancel | – |

Notes:

- `monitor.system` is one switch for the whole monitor, including the process list. Which cards are shown is a layout choice of the user, not a feature. To block the process list and its "Quit" action, disable `monitor.system`.
- `monitor.menubar` and `monitor.alerts` sample on their own and keep working when `monitor.system` is disabled. Together they cost about 0.37 % CPU with the panel closed (see [MEASUREMENTS.md](MEASUREMENTS.md)).
- Older per-metric IDs (`monitor.cpu`, `monitor.memory`, `monitor.disk`, `monitor.network`, `monitor.power`, `monitor.thermal`, `monitor.gpu`, `monitor.processes`) are no longer used and are ignored in a policy.
- On a Mac without Munki, `support.updates` shows only what macOS Software Update recommends.

## Private interfaces

| Name | Used for | When disabled |
|---|---|---|
| `NetworkStatistics` | Upload and download: bytes per connection over Wi-Fi, wired and cellular | Interface counters are used. Behind a network filter or VPN client the download is then "not measurable"; upload stays correct |
| `HIDSensors` | Temperatures on Apple silicon | No temperatures on Apple silicon |
| `SMC` | Fan speeds (read-only; MacHorus never writes to the SMC); temperatures on Intel Macs | No fan row; no temperatures on Intel Macs |
| `ProcessResponsibility` | Grouping helper processes under their app | Every process gets its own row |

`MacHorus --print-diagnosis` lists which private interfaces are allowed on a Mac (see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)).

## Permissions on managed Macs

Without an MDM, privacy permissions (TCC) cannot be granted in advance; each user grants them when a feature asks. Permissions survive updates as long as every build is signed with the same certificate, because the app's designated requirement pins the certificate. See [PRIVACY.md](PRIVACY.md) for the full list.

## Deploying with Munki (optional)

MacHorus has no built-in updater. The repository includes helpers to build an installer package and a Munki pkginfo; any other deployment tool that installs a package to `/Applications` works as well.

### Build

Run these in a regular Terminal session in the repository folder (the folder with the `Makefile`):

```bash
make check      # lint, build, tests
make release    # build/MacHorus.app + dist/MacHorus-<version>.pkg
make pkginfo    # dist/MacHorus-<version>.pkginfo
```

- The version comes from the `VERSION` file.
- The package installs `MacHorus.app` to `/Applications` and is not relocatable, so an update always replaces the app at the same path.
- `make release` refuses a package whose payload contains AppleDouble (`._`) files. Some sandboxed or automated shells tag every new file with extended attributes; build releases from a regular Terminal session.
- `make pkginfo` needs the Munki tools in `/usr/local/munki`. The catalog defaults to `testing`; choose another with `MUNKI_CATALOG=<catalog> make pkginfo`.

Then copy the `.pkg` to `pkgs/` and the `.pkginfo` to `pkgsinfo/` in your Munki repository and run `makecatalogs`.

### What the pkginfo sets

| Key | Value | Why |
|---|---|---|
| `minimum_os_version` | 14.2 | Minimum macOS version of the app |
| `supported_architectures` | `arm64`, `x86_64` | Universal binary for Apple silicon and Intel |
| `unattended_install` | true | Updates without user interaction |
| `blocking_applications` | empty array | MacHorus is always running; without an explicit empty list Munki would wait for it to quit and never update unattended |
| `installs` | `/Applications/MacHorus.app`, compared by `CFBundleShortVersionString` | Munki detects the installed version from the app itself, not only from the package receipt |
| `postinstall_script` | `packaging/munki/postinstall.sh` | Relaunches MacHorus for the logged-in user, see below |

### Postinstall behaviour

- MacHorus was running: it is quit and the new version is started.
- MacHorus never ran for this user (first install): it is started; its first launch turns "Open at login" on.
- The user had quit MacHorus: it stays quit and opens at the next login if "Open at login" is on.
- Nobody is logged in at the console: nothing is started.

`make check` tests the script with stubbed system commands (`scripts/test-postinstall.sh`).

### Importing the app instead of the package

If you import `MacHorus.app` directly (`munkiimport MacHorus.app`), the keys above are not set for you. Set them in the pkginfo by hand: `blocking_applications` as an **empty array**, `unattended_install` true, `postinstall_script` with the contents of `packaging/munki/postinstall.sh`, `minimum_os_version` 14.2, and `supported_architectures` `arm64` and `x86_64`.

### Updates and removal

- User settings live in `~/Library/Preferences/app.machorus.MacHorus.plist` and are never overwritten by an update. New features are added by a settings migration; earlier choices are kept.
- "Open at login" stays registered across updates (same path, same signature).
- When Munki removes the package, the user's settings file stays in place.
- A policy file can be deployed as a separate package (see [Policy files](#policy-files)).
