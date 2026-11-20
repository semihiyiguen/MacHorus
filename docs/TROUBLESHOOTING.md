# Troubleshooting

## "–" and "?" in widgets

A monitor widget shows **"–"** when there is no value and **"?"** when a reading was impossible. The caption below the value says why.

| What you see | Likely cause | What helps |
|---|---|---|
| "Measuring …" | The panel was just opened; the first reading is under way (values refresh every 2 s) | Wait a moment |
| "No network connection" | No active Wi-Fi or wired connection | Check the connection; run Tools → Network Check |
| "Download not measurable (network filter or VPN)" | Security software or a VPN client re-injects incoming traffic, so macOS does not count it per interface, and the more accurate per-connection measurement (`NetworkStatistics`) is unavailable or disabled by policy | Expected with such software; upload is still correct. See [MEASUREMENTS.md](MEASUREMENTS.md#network) |
| "This Mac reports no temperature" | The Mac has no readable sensors, or a policy disables `HIDSensors` (or `SMC` on Intel Macs) | Check "Private interfaces allowed" and "temperature" in the diagnosis |
| "?" with "Implausible reading" | A reading was outside what any Mac can deliver (for example a battery above 100 % or a temperature above 125 °C) | A single occurrence is an outlier. If it persists, open an issue with the diagnosis attached |
| "No reading" | The source returned nothing, for an unknown reason | Close and reopen the panel. If it persists, open an issue with the diagnosis attached |
| A widget is missing from "+ Widget" (temperatures, GPU, battery) | This Mac cannot measure the value: no battery in a desktop Mac, no GPU statistics from the driver, no sensors found | Nothing to fix; the diagnosis shows "Measurable on this Mac" |

The limits behind "Implausible reading" are listed in [MEASUREMENTS.md](MEASUREMENTS.md#plausibility-checks).

## Other common issues

| Problem | Cause and fix |
|---|---|
| A notification appears without sound | Sound is off for MacHorus in macOS, a Focus is active, or the alert volume is low or plays through another device (for example a headset). Check System Settings → Notifications → MacHorus → "Play sound for notifications", and System Settings → Sound → alert volume and "Play sound effects through" |
| No notifications at all | Settings → Alerts shows what macOS allows. Click "Allow notifications", or switch them on in System Settings → Notifications → MacHorus |
| Only your own processes are listed | macOS 27 does not let normal apps read other users' processes (system services). The footer below the list says so. Quitting is always limited to your own processes |
| "Sound per App" does not change an app's volume | macOS asks for "System Audio Recording Only" at the first adjustment. If it was denied, allow it in System Settings → Privacy & Security → Screen & System Audio Recording |
| Clipboard history stays empty | The feature is off, the copy came from a password manager or was marked private (the card says why), or macOS did not allow MacHorus to paste from other apps |
| MacHorus does not start after login | Settings → Features → "Open at login" shows the real state from macOS; also check System Settings → General → Login Items |
| A feature is disruptive | Switch it off in Settings → Features. Switched-off features do not run at all. A feature shown as locked is controlled by a policy file (see [ADMINISTRATION.md](ADMINISTRATION.md)) |
| Permissions are asked again after every build | A locally built app without a stable signing identity is signed ad hoc. Run `scripts/setup-signing.sh` once so permissions survive rebuilds |

## Network check

Tools → Network Check runs four steps when you click "Start check": connection, router, name lookup (DNS) and internet (see [PRIVACY.md](PRIVACY.md#network-connections) for what it contacts).

| Result | Meaning |
|---|---|
| All good (the router only ignores pings) | Many routers do not answer pings; the internet works, so this is not a problem |
| No connection | No interface has an address: check Wi-Fi or cable |
| The router does not answer | Check the router or Wi-Fi |
| Names do not resolve (DNS) | The router is reachable, but DNS fails |
| No internet | Everything local works; the problem is with the provider or the VPN |
| A Wi-Fi login page is in the way | Someone other than Apple answered the check address: sign in with the browser |

## Diagnosis for bug reports

When a value is missing or wrong, include the diagnosis in your bug report. Run in Terminal:

```bash
/Applications/MacHorus.app/Contents/MacOS/MacHorus --print-diagnosis
```

It does not need MacHorus to be running. It measures one fresh round (about one second), prints the result and exits. Settings are only read, never changed.

The output contains:

- MacHorus version and build, Mac model identifier (for example `MacBookPro17,1`)
- Private interfaces allowed by policy
- What this Mac can measure: CPU, memory, disk, network, processes, GPU, temperature sensor groups, number of fans, battery
- One fresh round of readings: CPU, memory and swap, free disk space, network rates, measurement method (`connections`, `interfaces` or `interfacesInboundBlind`) and whether a connection exists, temperatures and thermal state, GPU load, battery charge, health and cycles
- Implausible readings, if any
- Feature IDs that are on, and the settings schema version

It does **not** contain a serial number, computer name, user name, network addresses or app names. Review the text before posting it.

## Supported Macs

MacHorus runs on **every Mac with macOS 14.2 Sonoma or later**, with Apple silicon or an Intel processor. The app is a universal binary (`arm64` + `x86_64`); it needs neither Rosetta nor a separate download per processor.

| macOS | Macs (according to Apple) |
|---|---|
| 14 Sonoma (14.2 or later) | MacBook Air 2018 and later, MacBook Pro 2018 and later, Mac mini 2018 and later, iMac 2019 and later, iMac Pro (2017), Mac Pro 2019 and later, Mac Studio, all Macs with Apple silicon |
| 15 Sequoia | As Sonoma, without MacBook Air 2018/2019 |
| 26 Tahoe | Last version for Intel Macs (MacBook Pro 16" 2019, MacBook Pro 13" 2020 with four Thunderbolt ports, iMac 2020, Mac Pro 2019) and all Macs with Apple silicon |
| 27 | Apple silicon only |

- **Older than macOS 14.2:** not supported. 14.2 is required for "Sound per App" (Core Audio process taps).
- **Intel Macs:** everything runs. Performance/efficiency core rows are not shown, and temperatures come from SMC keys instead of HID sensors. Intel Macs and macOS 14 have had less real-world testing than recent Apple silicon Macs; reports are welcome.
- **Macs without a battery** (iMac, Mac mini, Mac Studio, Mac Pro): the battery widget is not offered; the layout closes the gap.
