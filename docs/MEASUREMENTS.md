# Measurements

This document describes where every value in MacHorus comes from, how it is calculated, how often it is read, what it costs, and how its correctness was checked against the tools that ship with macOS.

All monitor values are read-only and need no permission. The core samplers (CPU, memory, disk, network totals, battery, temperatures, GPU, processes) use kernel and IOKit interfaces directly and start no subprocesses. Two views call a macOS command-line tool instead: network use per app (`/usr/bin/nettop`) and the names of connected VPN services (`/usr/sbin/scutil --nc list`).

Four values use private Apple interfaces. Each has a public fallback and can be switched off by an administrator (see [ADMINISTRATION.md](ADMINISTRATION.md) and [PRIVACY.md](PRIVACY.md)):

| Private interface | Used for |
|---|---|
| `NetworkStatistics` | Upload and download totals |
| `HIDSensors` | Temperatures on Apple silicon |
| `SMC` | Fan speeds (and temperatures on Intel Macs), read-only |
| `ProcessResponsibility` | Grouping helper processes under their app |

## When values are measured

| Situation | Interval |
|---|---|
| Panel open, a monitor value visible | every 2 s |
| Battery, temperatures, process list | every second round (every 4 s), but immediately when the panel opens |
| Panel closed, only menu bar values or alerts active | every 4 s |
| Network use per app (`nettop`) | every 3 s while the network list is on screen; once a minute in the background while the system monitor is on |
| Screen locked, asleep, or another user active | nothing (menu bar values and alerts pause) |
| Feature switched off | nothing; the feature is not even created |

Sampling runs only while something shows a value. When the last consumer goes away, the engine stops and returns only after the current round has finished (test `engineDeliversSnapshotsAndStops`).

## Verification tools

The repository contains scripts that compare MacHorus with macOS's own tools in the same seconds:

```bash
make app
python3 -I scripts/dev/verify-monitor.py              # normal operation
python3 -I scripts/dev/verify-monitor.py --load       # all cores busy
python3 -I scripts/dev/verify-monitor.py --network    # 10 MB download compared with nettop
python3 -I scripts/dev/verify-monitor.py --thermal    # CPU and GPU load, compared with an independent SMC reader
MACHORUS_THERMAL_LOAD=150 python3 -I scripts/dev/verify-monitor.py --thermal  # long enough for the fan to start
python3 -I scripts/dev/verify-monitor.py --processes  # busy process and top memory compared with top, groups with ps
python3 -I scripts/dev/verify-tools.py                # updates, ports, microphones, audio processes
```

`verify-monitor.py` runs `MacHorus --print-monitor` and reads `vm_stat`, `sysctl`, `top`, `df`, `iostat`, `netstat`, `route`, `ipconfig`, `pmset`, `ioreg` and `system_profiler` at the same time, then prints PASS or FAIL per value. `--network` downloads a 10 MB test file (override with `MACHORUS_VERIFY_URL`); this download is part of the script only, never of the app.

Other command-line modes of the app binary (`MacHorus.app/Contents/MacOS/MacHorus`):

| Option | Output |
|---|---|
| `--print-monitor [rounds]` | One line of readings per round; add `--interface-counters` to force the network fallback, `--processes-ungrouped` to list every process on its own row |
| `--benchmark-samplers [rounds] [name]` | CPU time per sampler call |
| `--print-sensors` | Every temperature sensor and fan value |
| `--network-check` | Runs the network check once and prints each step |
| `--print-devices` | Drives, USB devices, power adapter, printers and print jobs |
| `--print-updates`, `--print-ports`, `--print-audio`, `--print-microphones`, `--print-audio-devices` | Raw data of the tools |
| `--print-diagnosis` | Diagnosis for bug reports (see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)) |

Example run on an Apple M1 MacBook Pro (8 cores, 16 GB):

| Value | MacHorus | macOS | Result |
|---|---|---|---|
| App memory | 6,859 MB | 6,845 MB (`vm_stat`) | PASS |
| Wired memory | 1,830 MB | 1,823 MB | PASS |
| Compressed | 1,973 MB | 1,973 MB | PASS |
| Cached files | 4,614 MB | 4,616 MB | PASS |
| Physical memory | 16,384 MB | 16,384 MB (`hw.memsize`) | PASS |
| Swap | 4,986 MB | 4,986 MB (`vm.swapusage`) | PASS |
| Memory pressure | 1 (normal) | 1 | PASS |
| Cores / performance cores | 8 / 4 | 8 / 4 (`hw.ncpu`, `hw.perflevel0`) | PASS |
| CPU total, full load | 94.4 % | 93.2 % (`top`) | PASS |
| CPU total, normal | 15.7 % | 13.2 % (`top`) | PASS |

Small memory differences come from memory changing between two queries a few milliseconds apart; the CPU windows of both tools start a few milliseconds apart.

## CPU

| Value | Source | Calculation |
|---|---|---|
| Total | `host_statistics(HOST_CPU_LOAD_INFO)` | Δ(user + nice + system) / Δ(user + nice + system + idle) between two readings |
| Per core | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | Same per core; the returned array is released with `vm_deallocate` |
| Performance / efficiency cores | `IODeviceTree:/cpus/cpuN` → `logical-cpu-id`, `cluster-type` | Checked against `hw.perflevel0/1.logicalcpu`; if they disagree, no core is labelled |

Counters that go backwards (a core came back online) count as "no data", not as a spike. Intel Macs have no performance/efficiency cores, so those rows are not shown.

## Memory

Same formulas as Activity Monitor. Source: `host_statistics64(HOST_VM_INFO64)`, page size from `hw.pagesize`.

| Value | Formula |
|---|---|
| App memory | (`internal_page_count` − `purgeable_count`) × page size |
| Wired | `wire_count` × page size |
| Compressed | `compressor_page_count` × page size |
| **Used** | App + Wired + Compressed |
| Cached files | (`external_page_count` + `purgeable_count`) × page size |
| Swap | `sysctl vm.swapusage` (`xsu_used`, `xsu_total`) |
| Memory pressure | `sysctl kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical |

## Disk

| Value | Source | Verification |
|---|---|---|
| Size, free | `statfs("/")`, i.e. the APFS container of the startup volume | `df -k /`: exact or ±4 KB |
| Read / write per second | Δ of the `Bytes (Read)` / `Bytes (Write)` statistics of all `IOBlockStorageDriver` entries; the handles are cached and refreshed every 30 rounds | Sum since start against `iostat -I`: ±4 MB at 271 GB |

"Free" does **not** include purgeable space that macOS could free on demand, matching `df` and `diskutil`. A counter that goes backwards (disk removed, driver reloaded) yields zero, not a spike.

## Network

| Value | Source | Verification |
|---|---|---|
| Upload / download per second (default) | `NetworkStatistics` (the framework behind `nettop` and Activity Monitor). Per TCP and UDP connection only the bytes over Wi-Fi, wired and cellular are counted (`kNStatSrcKeyRx/TxWiFiBytes`, `…Wired…`, `…Cellular…`), including connections that have closed since. Rate = Δ total / Δ time | `--network`, see below |
| Upload / download (fallback) | Δ of the 64-bit counters from `sysctl NET_RT_IFLIST2` for `en*` and `pdp_ip*`. Tunnels (`utun`), bridges and AirDrop links are skipped, otherwise bytes would be counted twice | Per interface against `netstat -ib`: exact |
| Primary interface | SystemConfiguration `State:/Network/Global/IPv4` → `PrimaryInterface` | `route -n get default`: same |
| Local IPv4 | `getifaddrs` of the primary interface | `ipconfig getifaddr en0`: same |
| VPN | Tunnel interfaces with an IPv4 address; connected VPN services from `scutil --nc list` (only while a tunnel is up); for clients without a system service, the client process | – |
| Wi-Fi signal | CoreWLAN: RSSI, noise, transmit rate, band. The network name is not read (it would need the Location permission). Good from −60 dBm, fair from −70 dBm, weak below | – |

Only byte counters are read from `NetworkStatistics`; process names and addresses in its records are never looked at. The kernel socket it needs is held only while the network value is shown (test `createAndDestroyRepeatedly`: 25 create/destroy cycles leave no file descriptor behind).

**Why connections and not interface counters.** Two situations make interface counters wrong:

- **Network filters.** Some endpoint security software re-injects incoming packets (observed with a content filter active, `net.cfil.active_count = 1`). The interface then never counts incoming bytes: a 1.2 MB download left `en0` at +0 bytes. Tools that read only interface counters show 0 download on such Macs.
- **VPN clients.** With a user-space VPN client, a download passes the kernel twice: encrypted over `en0` (the VPN client's connection) and decrypted over `utun` (the app's connection). Adding up all connections counts it twice. Counting only bytes over physical interfaces gives the real amount; a 10 MB download then shows about 10.6 MB, because the VPN adds about 6 % overhead per packet, which is exactly what crossed the Wi-Fi.

**Verification with `--network`.** The script starts `nettop -t wifi -t wired` and `MacHorus --print-monitor`, downloads 10 MB as soon as MacHorus has its first value, and compares the `nettop` samples whose second falls inside MacHorus' window. Example run on a Mac with a network filter and a VPN client:

| Check | MacHorus | Reference | Result |
|---|---|---|---|
| Received in window | 10,593,846 B | 10,594,127 B (`nettop`) | PASS (Δ 281 B) |
| Sent in window | 142,796 B | 143,883 B (`nettop`) | PASS |
| Received ≥ file size | 10,593,846 B | 10,000,000 B (`curl`) | PASS |
| Σ rate × round duration | 10,594,314 B | 10,593,846 B | PASS (Δ 0.004 %) |

**Display rules.**

- "–" means no value yet (first round, or the query did not answer within 1 s).
- "Not measurable" for the download appears only in the fallback, when the interface counters do not count incoming data (outgoing packets with not a single incoming one; TCP always acknowledges). Upload stays correct.

**Self-check.** If the outgoing interface counters grow by 1 MB while `NetworkStatistics` counts no byte at all, the framework is treated as broken (for example changed keys after a macOS update). MacHorus writes a log entry (category `monitor`) and switches to the interface counters.

### Network use per app

Per-process traffic comes from `nettop -L 1 -n -x -t external` (part of macOS; it reads the kernel's per-connection counters, needs no permission and sees every process). Each run costs about 30 ms CPU, so it runs every 3 s only while the list sorted by network is on screen, plus once a minute in the background while the system monitor is on, to keep totals since boot. Traffic is split into VPN (tunnel interfaces) and direct. Connections that opened and closed within one minute while the list was hidden can be missing from the totals.

## Temperatures and fans

macOS shows no temperatures anywhere, so there is no Apple tool to compare with. Verification therefore uses **two independent paths**: the app reads the chip's HID sensors, while `scripts/dev/smc-reference.swift` reads the SMC and shares no code with the app.

| Value | Source | Verification |
|---|---|---|
| Performance / efficiency cores | Hottest HID sensor named `pACC MTR Temp Sensor*` / `eACC MTR Temp Sensor*` | SMC `Tp?a` / `Te?a` |
| CPU on chips with other sensor names | Hottest die sensor (`PMU tdie*`, `PMU2 tdie*`, `PMGR SOC Die Temp Sensor*`) | – |
| GPU | Hottest `GPU MTR Temp Sensor*`; exactly 30.00 °C means "powered down", shown as "Idle" | Under GPU load 141 of 142 readings active, idle without load |
| SSD | `NAND CH*` | Plausibility |
| Battery | Hottest `gas gauge battery` | SMC `TB0T`–`TB2T`: same |
| Fans | SMC `FNum`, `F<n>Ac` (actual), `F<n>Mn`, `F<n>Mx`; 0 rpm = "Off" | Reference reader `F0Ac`: 150 stable pairs within 5 % |
| Intel Macs | First plausible SMC key, CPU: `TC0P`, `TC0D`, `TC0E`, `TC0F`, `TCXC`, `TC0H`; GPU: `TG0P`, `TG0D`, `TGDD` | – |
| Thermal state | `ProcessInfo.thermalState` (public) | – |

Readings outside 10–125 °C are discarded (observed: a sensor reporting −21.7 °C). The SMC is only read; MacHorus has no code path that writes to it.

Observations on an M1 MacBook Pro:

- The SMC CPU keys often cited for M1 (`Tp09`, `Tp01`, …) do not exist there. Instead there are groups ending in `a`, `b`, `x` and `z`: `a` is the reading and matches HID within 1–4 °C; `x` is a jumping window maximum; `b` and `z` read 7–17 °C higher. Taking the maximum of all `Tp` keys would show about 60 °C at idle instead of 30 °C.
- HID sensors update about every 4 s, the SMC about every second. At the panel's 2 s interval a value lags at most one round.
- The fan starts only at about 80 °C: the controller sets `F0Tg` from 0 to 1200, and `F0Ac` follows within ±2 %.

Example `--thermal` run (150 s load, fan running):

| Check | MacHorus | Reference | Result |
|---|---|---|---|
| CPU idle | 42.5 °C | 42.4 °C (SMC) | PASS |
| CPU at end of load | 93.9 °C | 93.9 °C (SMC) | PASS |
| CPU rises under load | 95.0 °C | ≥ idle + 8 | PASS |
| Battery | 33.5 °C | 33.5 °C (SMC) | PASS |
| GPU utilization under load | 100 % | ≥ 90 % | PASS |
| GPU temperature under load | 141 readings | of 142 | PASS |
| Fan (max pair) | 2,746 rpm | 2,762 rpm | PASS |

## GPU

| Value | Source | Verification |
|---|---|---|
| Utilization | I/O Registry `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %` (public) | Metal load (`scripts/dev/gpu-load.swift`): 0 % → 98–100 % → 0 % |
| Model, cores | `model`, `gpu-core-count` | Same as System Information |
| Memory in use | `In use system memory` | Plausibility: 32 MB idle, 82 MB under load |

Macs whose GPU driver publishes no statistics do not offer the GPU widget.

## Processes

| Value | Source | Verification |
|---|---|---|
| CPU per app | Δ(`ri_user_time` + `ri_system_time`) from `proc_pid_rusage`, converted to nanoseconds with the Mach timebase, divided by elapsed time; 100 % = one core, as in `top` and Activity Monitor | `yes` (constant load): 100.0 % vs. 99.9 % (`top`) |
| Memory per app | `ri_phys_footprint` (Activity Monitor's "Memory" column) | Five largest processes against `top` MEM: 974.9 = 975 MB, 803.0 = 803 MB, 605.3 = 605 MB, 478.1 = 478 MB, 451.9 = 452 MB |
| Grouping | Responsible process (`responsibility_get_pid_responsible_for_pid`); sums are preserved (test `groupsHelpersUnderTheirAppAndKeepsTheSums`) | The largest group contains at least 90 % of the processes inside its app bundle. It may contain more: tools an app launches live outside the bundle and correctly count towards it |
| Visible / hidden | Readable own processes / processes macOS refuses | Visible + hidden matches `ps -ax` (±1) |
| Groups complete | Sum of processes in all rows = visible processes | Equal |

Without the `ProcessResponsibility` interface every process gets its own row.

**Other users' processes.** On macOS 27, `proc_pid_rusage`, `proc_pidinfo` and `proc_name` fail for **every** process of another user, including WindowServer. `ps` and `top` are setuid root and still see them. MacHorus therefore shows only the user's own processes and says so below the list. Where older systems allow reading them, the footer says "All processes", and quitting is still limited to the user's own processes.

**Quitting.** Apps are asked to quit like ⌘Q. Other processes get `SIGTERM` after a confirmation; "Force Quit" sends `SIGKILL` after a confirmation. Before acting, MacHorus checks again that the process belongs to the user, still has the same start time (a recycled PID is rejected), is not MacHorus itself and is not `loginwindow` or `launchd`. The test `signalsOnlyTheSameOwnProcess` covers both the rejected recycled PID and the successful `SIGTERM`.

**Lesson about `top`.** The first two samples of `top -l` are unreliable (the second showed 63.1 % for `yes` while its TIME column grew by 1.11 s in that second). The script evaluates from the third sample on.

## Battery

| Value | Source | Verification |
|---|---|---|
| Charge, charging, time remaining | `IOPSCopyPowerSourcesInfo` (time = `Time to Empty` / `Time to Full Charge`) | `pmset -g batt`: exact. The registry values `AvgTimeToEmpty` / `TimeRemaining` differ |
| Cycle count | `AppleSmartBattery` → `CycleCount` | `system_profiler`: exact |
| Health ("Maximum Capacity") | `BatteryData.FullChargeCapacity` / `BatteryData.DesignCapacity` × 100, **rounded up** | `system_profiler`: usually equal, at most 1 point apart (see below) |
| Power | `BatteryData.BatteryPower` (mW, Apple's own figure); fallback voltage × amperage | `ioreg`: same |
| Power adapter | `AdapterDetails` → `Watts` | – |

Rounding up matches macOS (observed: 81.34 % is shown as 82 %; `NominalChargeCapacity` would give 84 %). The full-charge capacity fluctuates live (4154 → 4164 mAh within a minute), while macOS shows a smoothed value that is not readable from the I/O Registry or IOPowerSources, so the verification allows ±1 point. Since macOS 27 the capacities exist only inside `BatteryData`, no longer at the top level of the registry entry.

Macs without an internal battery do not offer the battery widget.

## Accessory batteries

Keyboards, mice and trackpads report their charge in the I/O Registry (`BatteryPercent`). MacHorus reads it without the Bluetooth permission; the device name is not read, the kind comes from the Apple product ID.

## Uptime and restart advice

| Value | Source | Verification |
|---|---|---|
| Uptime ("Up for") | `sysctl kern.boottime`; time asleep counts, as in `uptime` | Test `bootDateMatchesSysctl`: same to the second |
| Restart advice | Pure function `RestartAdvisor.advise` | Tests at every threshold and for the order of reasons |

The restart advice is MacHorus' own rule set, not an Apple guideline. Every reason is shown with its value, so the advice can be checked. The strongest reason sets the level.

| Reason | Low ("Restart when convenient") | Medium ("Restart advised") | High ("Restart needed") |
|---|---|---|---|
| Uptime | ≥ 7 days | ≥ 14 days | ≥ 30 days |
| Swap in use, as share of physical memory | ≥ 25 % | ≥ 50 % | ≥ 100 % |
| Memory pressure | – | warning | critical |

To check the display without a long uptime, launch with `-debug.uptimeOffsetDays 15 -debug.restartReasons YES`.

## Status on the overview

The overview lists what needs attention, worst first. Without any item it reports that all is well.

| Item | Rule | Severity |
|---|---|---|
| Restart reason | See above | High = red, otherwise yellow |
| Active alert | See below | CPU = yellow, others red |
| Startup disk almost full | Same limit as the disk alert (default < 10 % free); below half the limit | yellow / red |
| Battery worn | Health < 80 % | info |
| Thermal state | `serious` / `critical` | yellow / red |
| Pending updates | At least one pending Munki or macOS update | info |
| Accessory battery | ≤ 15 % / ≤ 5 % | yellow / red |
| Weak Wi-Fi | Wi-Fi is the primary connection and RSSI < −75 dBm | yellow |

Info items can be hidden until they change (another 5 points of battery wear, a different number of updates).

## Alerts

An alert fires when its condition holds for a hold time, then marks the eye in the menu bar, appears on the overview and, if allowed, as a notification. The same alert fires again only after a 15-minute cooldown. If two readings of a value are more than 30 s apart (sampling paused, e.g. while the screen was locked), the hold time starts again.

| Alert | Default condition | Hold time | Adjustable |
|---|---|---|---|
| CPU busy | Total CPU ≥ 90 % | 2 min | 70/80/90/95 %; 1/2/5/10 min |
| Hot | Hottest CPU sensor ≥ 90 °C, or thermal state `serious`/`critical` | 60 s | 80/85/90/95/100 °C |
| Memory pressure | Pressure `critical` | 30 s | on/off |
| Disk full | < 10 % free on the startup disk | immediate | 5/10/15/20 % or 10/20/50/100/200 GB |
| Battery low | < 15 % and not on external power | immediate | 5/10/15/20/30 % |

Each alert can be switched off. For CPU, heat and memory alerts MacHorus names the app with the highest load at the moment the alert fires.

Verification under real load (8 × `yes`, panel closed, menu bar captured with `screencapture`): normal eye after 100 s, eye with warning badge after 135 s, normal again 10 s after the load ended. The rules are covered by unit tests, including the pause rule.

## Plausibility checks

Every round is checked against what any Mac can deliver. An impossible value is shown as "?" in its widget, logged, and listed in the diagnosis.

| Metric | Implausible when |
|---|---|
| CPU | Total or any core outside 0–100 % |
| Memory | Physical memory 0; used > 105 % of physical; swap used > swap total |
| Disk | Size 0; free > size; read/write rate < 0 or > 50 GB/s |
| Network | Rate < 0 or > 100 Gbit/s |
| Battery | Charge outside 0–100 %; health outside 1–150 %; power beyond ±500 W |
| Temperatures | Any sensor outside 10–125 °C; fan outside 0–15,000 rpm |
| GPU | Utilization outside 0–100 % |

## Cost

### Per sampler

`MacHorus --benchmark-samplers 40`, CPU time per call, cold core as in normal operation (M1):

| Sampler | CPU time per call |
|---|---|
| CPU | 0.11 ms |
| Memory | 0.08 ms |
| Disk | 0.31 ms |
| Network, `NetworkStatistics` | 1.9–2.2 ms |
| Network, interface counters | 1.1–1.3 ms |
| Battery | 0.67 ms |
| Temperatures | 1.6 ms |
| GPU | 0.45 ms |
| Processes | 4.7–5.1 ms |

- CPU: two Mach calls per round. Memory: one Mach call plus a few sysctls.
- Network: only the six needed counters are read per connection, not the whole dictionary. With `NetworkStatistics` active, the interface counters are read only every fifth round (for the self-check). The interface name is taken from the routing message itself; calling `if_indextoname` instead would read all interfaces again and cost about 6.8 ms per round.
- Temperatures: the ~20 needed HID sensors are selected once at launch; fans: three SMC keys per fan; GPU: one registry entry.
- Processes: one `proc_pid_rusage` per process (it also returns the start time), names only for displayed rows, responsible app looked up once per process. About 94 % of the cost is the `proc_pid_rusage` calls themselves.
- The host port is fetched once and released on stop. `leaks --atExit` after 20 rounds with all values: 0 leaks.
- With the panel closed, the `NetworkStatistics` framework is not even loaded.

### Panel

Measured with `scripts/dev/panel-cost.py` (real popover, display on, all values on):

| Event | CPU time |
|---|---|
| First open after launch | 210–220 ms |
| Re-open | 60–110 ms |
| One round, Monitor page | 19–37 ms (≈ 1–1.8 % of one core) |
| One round, Overview page | 12.6–13.6 ms (≈ 0.65 %) |
| One round, Settings page | 7.6 ms (≈ 0.4 %) |
| Close | 20–35 ms |
| Panel closed, nothing in the menu bar | ≈ 0.1 ms/s, like an app that was never opened |

Live values are never animated: animated bars and numbers redraw the panel at the display refresh rate (3.48 % CPU in an early test).

The panel becomes the key window only when the search field is clicked. As key window, every redraw made AppKit set the cursor again; with a customized pointer (Accessibility → Display → Pointer) macOS rebuilds the pointer image each time, which cost up to 177 ms instead of 21 ms per round while the mouse was over the panel.

### Menu bar values

Panel closed, display on:

| Values | Per refresh | CPU |
|---|---|---|
| None (feature off) | 0 ms | 0 % |
| Battery only (rarely changes) | 0.6–0.7 ms per 2 s | 0.03 % |
| CPU only, every 2 s | 11.6–14.5 ms | 0.6–0.7 % |
| CPU + memory, every 4 s | 6.4–6.8 ms | 0.32–0.34 % |
| CPU, memory, temperature, network, every 4 s | 9.5 ms | 0.47 % |

The cost arises per change of the menu bar item (it goes through the system's menu bar agent), not from measuring. That is why menu bar values refresh every 4 s.

With the screen locked, menu bar values and alerts stop: a lock trace showed 0.41 % CPU unlocked, 0.02 % locked, and no sampling rounds during the lock.

### Alerts

Panel closed, display on, idle, 60 s:

| State | CPU time per 60 s | CPU |
|---|---|---|
| Monitor on, nothing visible | 1.0 ms | ≈ 0 % |
| Alerts only | 24.5–26.5 ms | ≈ 0.04 % |
| Alerts + menu bar with CPU and memory | 219 ms | 0.37 % |

### Sound per app

| State (panel closed) | CPU |
|---|---|
| Feature on, no app adjusted | ≈ 0 % |
| One app muted | ≈ 0.02 % |
| One app turned down (aggregate device running) | ≈ 0.36 % |

The cost of a volume tap arises in the audio system (about 94 render cycles per second), not in the level loop. Correctness was checked with `-debug.mixerSelfTest`, which taps a running `afplay` and compares peak levels before and after: at 25 % the output/input ratio was 0.250, at 0 % it was 0.000. A tap ends with the app or with MacHorus; macOS then gives every app its sound back.

### Clipboard history

- Polling `NSPasteboard.changeCount` costs 0.7–0.8 µs per call; every 0.5 s that is about 0.0002 % of one core. Contents are read only after a change, and nothing is read while the screen is locked or asleep.
- The history is limited by the whole app's memory (100, 250 or 500 MB, default 250 MB). When the limit is reached, the oldest 50 MB go; the newest entry always stays. Single copies larger than 50 MB are not kept.

### Tools

| Tool | Source | Verification |
|---|---|---|
| Keep awake | Named power assertion (`PreventUserIdleSystemSleep`, or `PreventUserIdleDisplaySleep` when the display should stay on), like `caffeinate` | `pmset -g assertions` shows "MacHorus: keep awake"; gone after the period ends and after `kill -TERM` |
| Mute all microphones | CoreAudio device mute, or input volume 0 where a device has no mute; virtual and aggregate devices are skipped | Independent reader of `kAudioDevicePropertyMute` / `kAudioDevicePropertyVolumeScalar`; restored after `kill -TERM`; after `kill -KILL` restored at the next launch |
| Software updates | Local Munki and Software Update files | Same plist files read independently in Python |
| Open ports | libproc, like `lsof -iTCP -sTCP:LISTEN` without a subprocess | `lsof -a -nP -iTCP -sTCP:LISTEN -u <uid>`: same ports and PIDs |
| Microphones | CoreAudio input devices | `system_profiler SPAudioDataType` |
| Who plays sound / uses a microphone | CoreAudio process objects (states only, never audio) | `verify-tools.py` starts `afplay` and finds that process |

### Self usage

The panel footer shows MacHorus' own CPU and memory. Memory is `ri_phys_footprint`, Activity Monitor's "Memory" column; the test `SelfUsageAccuracyTests` allows less than 1 MB difference. Checked externally with `footprint` and `top` as well.
