#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 MacHorus contributors
"""Compares MacHorus' monitor readings with macOS' own tools.

Runs `MacHorus --print-monitor`, reads vm_stat, sysctl, top, df, iostat,
netstat, route, ipconfig, pmset, ioreg and system_profiler over the same
seconds and prints PASS/FAIL per value. With --load every core is kept busy
first, so both sides must report ~100 % CPU. With --network a 10 MB file is
downloaded while MacHorus and `nettop -t wifi -t wired` count the bytes on
the physical interfaces (MACHORUS_VERIFY_URL overrides the file). With
--thermal CPU and GPU are loaded for 18 s while the app's temperatures (HID
sensors) are compared with an independent SMC reader; macOS itself shows no
temperatures. MACHORUS_THERMAL_LOAD=150 loads long enough for the fan to
start (Apple Silicon fans stay off until about 80 °C). With --processes a
busy `yes` and the five largest processes are compared with top, and the
grouping of helpers with ps. Usage:
    python3 -I scripts/dev/verify-monitor.py [--load] [--network] [--thermal] [--processes] [path/to/MacHorus]
"""

import os
import re
import subprocess
import sys
import threading
import time

FLAGS = {"--load", "--network", "--thermal", "--processes"}
ARGS = [arg for arg in sys.argv[1:] if arg not in FLAGS]
LOAD = "--load" in sys.argv
NETWORK = "--network" in sys.argv
THERMAL = "--thermal" in sys.argv
PROCESSES = "--processes" in sys.argv
DOWNLOAD_URL = os.environ.get("MACHORUS_VERIFY_URL", "https://speed.cloudflare.com/__down?bytes=10000000")
BINARY = ARGS[0] if ARGS else "build/MacHorus.app/Contents/MacOS/MacHorus"
ROUNDS = 3
MB = 1024 * 1024


def run(*command):
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout


def sysctl(name):
    return run("/usr/sbin/sysctl", "-n", name).strip()


def vm_stat():
    output = run("/usr/bin/vm_stat")
    page_size = int(re.search(r"page size of (\d+) bytes", output).group(1))
    pages = {key.strip(): int(value.strip().rstrip(".")) for key, value in re.findall(r"^(.+?):\s+(\d+)\.?$", output, re.M)}
    return page_size, pages


def netstat_links():
    """Byte and packet counters per interface from `netstat -ib` (Link rows)."""
    links = {}
    for line in run("/usr/sbin/netstat", "-ib").splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 10 and fields[2].startswith("<Link"):
            # Rows without a MAC address have one column less.
            offset = 0 if ":" in fields[3] else -1
            links[fields[0].rstrip("*")] = {
                "ipackets": int(fields[4 + offset]), "ibytes": int(fields[6 + offset]),
                "opackets": int(fields[7 + offset]), "obytes": int(fields[9 + offset]),
            }
    return links


def iostat_total_mb():
    lines = run("/usr/sbin/iostat", "-Id", "-K").splitlines()
    values = [float(value) for value in lines[-1].split()]
    # Three columns per disk: KB/t, xfrs, MB.
    return sum(values[2::3])


def pmset_battery():
    line = run("/usr/bin/pmset", "-g", "batt").splitlines()[-1]
    match = re.search(r"(\d+)%; ([^;]+);(?: (\d+):(\d+) remaining)?", line)
    if not match:
        return None
    minutes = int(match.group(3)) * 60 + int(match.group(4)) if match.group(3) else None
    return {"charge": int(match.group(1)), "state": match.group(2).strip(), "minutes": minutes}


def system_profiler_battery():
    output = run("/usr/sbin/system_profiler", "SPPowerDataType")
    cycles = re.search(r"Cycle Count: (\d+)", output)
    # system_profiler separates value and "%" with a no-break space.
    health = re.search(r"Maximum Capacity:\s*(\d+)\s*%", output)
    return (int(cycles.group(1)) if cycles else None, int(health.group(1)) if health else None)


def ioreg_battery_power():
    output = run("/usr/sbin/ioreg", "-rn", "AppleSmartBattery", "-a")
    import plistlib
    entries = plistlib.loads(output.encode())
    return entries[0].get("BatteryData", {}).get("BatteryPower") if entries else None


def top_cpu(result):
    # top's first sample covers time since boot; the next ROUNDS cover the
    # same seconds as our rounds. Compare the averages.
    output = run("/usr/bin/top", "-l", str(ROUNDS + 1), "-s", "1", "-n", "0")
    lines = [line for line in output.splitlines() if line.startswith("CPU usage")][1:]
    loads = []
    for line in lines:
        user, system = re.findall(r"([\d.]+)% (?:user|sys)", line)[:2]
        loads.append((float(user) + float(system)) / 100)
    result["top"] = sum(loads) / len(loads)


def fields(line):
    return dict(field.split("=", 1) for field in line.split())


def nettop_samples(samples, result):
    """Bytes in and out over all processes on Wi-Fi and wired per delta
    sample, with the sample's time (the first sample is cumulative)."""
    output = run("/usr/bin/nettop", "-t", "wifi", "-t", "wired", "-P", "-d", "-x", "-L", str(samples), "-s", "1",
                 "-J", "time,bytes_in,bytes_out")
    today = time.strftime("%Y-%m-%d")
    result["nettop"] = []
    for block in output.split("time,,bytes_in,bytes_out,")[2:]:
        rows = [row.split(",") for row in block.strip().splitlines()]
        rows = [row for row in rows if len(row) >= 4 and row[2].isdigit()]
        if not rows:
            continue
        clock, fraction = rows[0][0].split(".")
        stamp = time.mktime(time.strptime(f"{today} {clock}", "%Y-%m-%d %H:%M:%S")) + float("0." + fraction)
        result["nettop"].append((stamp, sum(int(r[2]) for r in rows), sum(int(r[3]) for r in rows)))


def network_checks():
    """Counts a download on both sides over the same seconds."""
    rounds = 8
    result = {}
    worker = threading.Thread(target=nettop_samples, args=(14, result))
    worker.start()
    time.sleep(1.2)
    probe = subprocess.Popen([BINARY, "--print-monitor", str(rounds)], stdout=subprocess.PIPE, text=True)
    # Download only once MacHorus has its first reading, so its window
    # contains the whole download even if the app starts slowly.
    lines = [probe.stdout.readline().strip()]
    time.sleep(0.5)
    downloaded = int(run("/usr/bin/curl", "-sS", "-o", "/dev/null", "-w", "%{size_download}", DOWNLOAD_URL))
    lines += probe.communicate()[0].strip().splitlines()
    worker.join()
    readings = [fields(line) for line in lines]
    if any(r.get("net.measurement") != "connections" for r in readings):
        return [("net.measurement", readings[-1].get("net.measurement"), "connections", "", False)]
    start, end = float(readings[0]["time"]), float(readings[-1]["time"])
    received = int(readings[-1]["net.connections.rx"]) - int(readings[0]["net.connections.rx"])
    sent = int(readings[-1]["net.connections.tx"]) - int(readings[0]["net.connections.tx"])
    # A nettop sample covers the second before its time stamp; take the
    # samples whose middle lies in our window.
    window = [sample for sample in result["nettop"] if start < sample[0] - 0.5 <= end]
    theirs_received = sum(sample[1] for sample in window)
    theirs_sent = sum(sample[2] for sample in window)
    # Rate times round length must add up to the bytes.
    integrated = sum(float(new["net.downRate"]) * (float(new["time"]) - float(old["time"]))
                     for old, new in zip(readings, readings[1:]) if new["net.downRate"] != "-")
    kb = 1024
    return [
        # The windows can be up to half a second apart at both ends: allow
        # 64 KB of background traffic, or 0.5 %.
        ("net.rx during download", received, theirs_received, "B",
         abs(received - theirs_received) <= max(64 * kb, 0.005 * theirs_received)),
        ("net.tx during download", sent, theirs_sent, "B",
         abs(sent - theirs_sent) <= max(64 * kb, 0.02 * theirs_sent)),
        # Physical bytes cover at least the payload; VPN framing adds ~6 %.
        ("net.rx vs file size", received, downloaded, "B", downloaded <= received <= 1.10 * downloaded + 256 * kb),
        ("net.rates x seconds", integrated, received, "B", abs(integrated - received) <= 0.02 * received),
    ]


def start_collecting(command):
    """Starts a process and reads its lines while it runs; a full pipe
    would otherwise block it (seen: 166 one-second rounds took 262 s)."""
    process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
    lines = []
    reader = threading.Thread(target=lambda: lines.extend(line.strip() for line in process.stdout))
    reader.start()
    return process, reader, lines


def dev_tool(name):
    """Compiles scripts/dev/<name>.swift once into .build/dev."""
    source, binary = f"scripts/dev/{name}.swift", f".build/dev/{name}"
    if not os.path.exists(binary) or os.path.getmtime(binary) < os.path.getmtime(source):
        os.makedirs(".build/dev", exist_ok=True)
        run("/usr/bin/swiftc", "-O", source, "-o", binary)
    return binary


def number(value):
    return None if value in (None, "-") else float(value)


def thermal_checks():
    """Idle 6 s, CPU and GPU load (18 s by default), cool-down 10 s."""
    load = int(os.environ.get("MACHORUS_THERMAL_LOAD", "18"))
    idle = 6
    seconds = idle + load + 10
    cpu_keys = [f"Tp{i}a" for i in range(10)] + [f"Te{i}a" for i in range(10)]
    battery_keys = ["TB0T", "TB1T", "TB2T"]
    reference = start_collecting([dev_tool("smc-reference"), str(seconds), *cpu_keys, *battery_keys, "F0Ac"])
    probe = start_collecting([BINARY, "--print-monitor", str(seconds)])
    gpu_tool = dev_tool("gpu-load")
    time.sleep(idle)
    started = time.time()
    burners = [subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL) for _ in range(int(sysctl("hw.ncpu")))]
    burners.append(subprocess.Popen([gpu_tool, str(load)]))
    time.sleep(load)
    ended = time.time()
    for process in burners:
        process.kill()
    for process, reader, _ in (probe, reference):
        process.wait()
        reader.join()
    ours = [fields(line) for line in probe[2] if line]
    theirs = [fields(line) for line in reference[2] if line]

    def nearest(reading):
        return min(theirs, key=lambda r: abs(float(r["time"]) - float(reading["time"])))

    def smc_max(row, keys):
        values = [number(row.get(k)) for k in keys]
        values = [v for v in values if v is not None and 10 <= v < 125]
        return max(values) if values else None

    def app_cpu(r):
        values = [number(r["thermal.performanceCores"]), number(r["thermal.efficiencyCores"])]
        values = [v for v in values if v is not None]
        return max(values) if values else None

    phase_idle = [r for r in ours if float(r["time"]) < started]
    phase_load = [r for r in ours if started + 2 <= float(r["time"]) <= ended]
    load_end = [r for r in ours if ended - 4 <= float(r["time"]) <= ended]
    checks = []
    if smc_max(theirs[0], cpu_keys) is None:
        checks.append(("thermal.cpu vs SMC", "skip", "no Tp?a keys", "", True))
    else:
        for name, phase, tolerance in (("thermal.cpu idle", phase_idle, 5), ("thermal.cpu end of load", load_end, 6)):
            mine = sum(app_cpu(r) for r in phase) / len(phase)
            reference_value = sum(smc_max(nearest(r), cpu_keys) for r in phase) / len(phase)
            checks.append((name, mine, reference_value, "C", abs(mine - reference_value) <= tolerance))
    idle_cpu = sum(app_cpu(r) for r in phase_idle) / len(phase_idle)
    peak_cpu = max(app_cpu(r) for r in phase_load)
    checks.append(("thermal.cpu rises", peak_cpu, idle_cpu + 8, "C", peak_cpu >= idle_cpu + 8))
    battery_mine = [number(r["thermal.battery"]) for r in ours if number(r["thermal.battery"]) is not None]
    battery_theirs = [smc_max(nearest(r), battery_keys) for r in ours]
    battery_theirs = [v for v in battery_theirs if v is not None]
    if battery_mine and battery_theirs:
        mine, other = sum(battery_mine) / len(battery_mine), sum(battery_theirs) / len(battery_theirs)
        checks.append(("thermal.battery", mine, other, "C", abs(mine - other) <= 1.5))
    gpu_peak = max(float(r["gpu.utilization"]) for r in phase_load)
    checks.append(("gpu.utilization load", gpu_peak * 100, 90, "%", gpu_peak >= 0.9))
    gpu_active = sum(r["thermal.gpu"] != "-" for r in phase_load)
    checks.append(("thermal.gpu under load", gpu_active, len(phase_load), "", gpu_active >= len(phase_load) / 2))
    # Fans ramp by hundreds of rpm per second and both readers run up to
    # 0.5 s apart: compare only while the reference is steady (< 5 % change
    # over its neighbouring seconds).
    steady = []
    for reading in ours:
        mine = number(reading.get("thermal.fan0.rpm"))
        index = theirs.index(nearest(reading))
        window = [number(row.get("F0Ac")) for row in theirs[max(0, index - 1):index + 2]]
        if mine is None or None in window or len(window) < 3:
            continue
        if max(window) - min(window) <= 0.05 * max(window[1], 1):
            steady.append((mine, window[1]))
    if steady:
        running = [pair for pair in steady if pair[1] > 0]
        worst = max(abs(a - b) - max(0.05 * b, 30) for a, b in steady)
        shown = max(running, key=lambda pair: pair[1]) if running else steady[-1]
        checks.append((f"thermal.fan0.rpm ({len(running)} on)", shown[0], shown[1], "rpm", worst <= 0))
    return checks


def top_memory(text):
    """top's MEM column, e.g. 976M, 1024K, 1.2G (sometimes with + or -)."""
    match = re.fullmatch(r"([\d.]+)([KMG])[+-]?", text)
    if not match:
        return None, None
    unit = {"K": 1024, "M": MB, "G": 1024 * MB}[match.group(2)]
    return float(match.group(1)) * unit, unit


def process_checks():
    checks = []
    busy = subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL)
    try:
        time.sleep(2)
        top_cpu = {}
        worker = threading.Thread(target=lambda: top_cpu.update(
            out=run("/usr/bin/top", "-l", "5", "-s", "1", "-stats", "pid,cpu", "-pid", str(busy.pid))))
        worker.start()
        lines = run(BINARY, "--print-monitor", "3", "--processes-ungrouped").strip().splitlines()
        worker.join()
    finally:
        busy.kill()
    values = fields(lines[-1])
    # CPU: the busy process must lead with one full core on both sides.
    # top's first two samples are off: the second showed 63 % while its own
    # TIME column grew by 1.11 s in one second. Use the later ones.
    samples = [float(row.split()[1]) for row in top_cpu["out"].splitlines() if row.split()[:1] == [str(busy.pid)]]
    theirs = sum(samples[2:]) / len(samples[2:])
    mine = float(values["proc.cpu0.value"]) * 100 if values.get("proc.cpu0.pid") == str(busy.pid) else 0
    checks.append(("proc busy yes cpu", mine, theirs, "%", abs(mine - theirs) <= 10 and mine >= 90))
    # Memory: the five largest processes against top's MEM (rounded there).
    pids = [values[f"proc.mem{i}.pid"] for i in range(5) if f"proc.mem{i}.pid" in values]
    output = run("/usr/bin/top", "-l", "1", "-stats", "pid,mem", *[arg for pid in pids for arg in ("-pid", pid)])
    reported = {row.split()[0]: row.split()[1] for row in output.splitlines() if len(row.split()) == 2}
    for index, pid in enumerate(pids):
        ours = int(values[f"proc.mem{index}.bytes"])
        theirs, unit = top_memory(reported.get(pid, ""))
        ok = theirs is not None and abs(ours - theirs) <= max(0.02 * theirs, unit)
        checks.append((f"proc mem #{index + 1} (pid {pid})", ours / MB, (theirs or 0) / MB, "MB", ok))
    # Visible + hidden must be every process: ps (setuid root) sees all.
    total = len(run("/bin/ps", "-axo", "pid=").split())
    counted = int(values["proc.visible"]) + int(values["proc.hidden"])
    checks.append(("proc visible+hidden", counted, total, "", abs(counted - total) <= 10))
    # Grouping keeps every process exactly once.
    grouped = fields(run(BINARY, "--print-monitor", "2").strip().splitlines()[-1])
    checks.append(("proc grouped = visible", int(grouped["proc.grouped"]), int(grouped["proc.visible"]), "",
                   grouped["proc.grouped"] == grouped["proc.visible"]))
    # The largest app with helpers holds the processes inside its bundle;
    # it may hold more (tools it started live elsewhere, e.g. a terminal).
    commands = {row.split(None, 1)[0]: row.split(None, 1)[1] for row in
                run("/bin/ps", "-axo", "pid=,comm=").strip().splitlines() if len(row.split(None, 1)) == 2}
    for index in range(5):
        owner, count = grouped.get(f"proc.mem{index}.pid"), int(grouped.get(f"proc.mem{index}.count", "0"))
        bundle = commands.get(owner or "", "").split(".app/")[0] + ".app/"
        if count > 1 and ".app/" in commands.get(owner, ""):
            inside = sum(1 for command in commands.values() if command.startswith(bundle))
            checks.append((f"proc group pid {owner}", count, inside, "", count >= 0.9 * inside))
            break
    return checks


def main():
    if PROCESSES:
        return report(process_checks())
    if NETWORK:
        return report(network_checks())
    if THERMAL:
        return report(thermal_checks())
    load = []
    if LOAD:
        load = [subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL) for _ in range(int(sysctl("hw.ncpu")))]
    try:
        result = {}
        links_before = netstat_links()
        # The time-remaining estimate moves with the load: bracket the probe.
        pmset_before = pmset_battery()
        worker = threading.Thread(target=top_cpu, args=(result,))
        worker.start()
        rounds = run(BINARY, "--print-monitor", str(ROUNDS)).strip().splitlines()
        links_after = netstat_links()
        worker.join()
    finally:
        for process in load:
            process.kill()
    page_size, pages = vm_stat()
    values = fields(rounds[-1])
    cpu_average = sum(float(fields(line)["cpu.total"]) for line in rounds) / len(rounds)

    reference_app = (pages["Anonymous pages"] - pages["Pages purgeable"]) * page_size
    reference = {
        "mem.app": reference_app,
        "mem.wired": pages["Pages wired down"] * page_size,
        "mem.compressed": pages["Pages occupied by compressor"] * page_size,
        "mem.cached": (pages["File-backed pages"] + pages["Pages purgeable"]) * page_size,
    }
    swap_used = float(re.search(r"used = ([\d.]+)M", sysctl("vm.swapusage")).group(1)) * MB

    checks = []
    for key, expected in reference.items():
        # Memory moves between the two reads: allow 3 % or 128 MB.
        tolerance = max(0.03 * expected, 128 * MB)
        checks.append((key, int(values[key]) / MB, expected / MB, "MB", abs(int(values[key]) - expected) <= tolerance))
    checks.append(("mem.physical", int(values["mem.physical"]) / MB, int(sysctl("hw.memsize")) / MB, "MB",
                   int(values["mem.physical"]) == int(sysctl("hw.memsize"))))
    checks.append(("mem.swapUsed", int(values["mem.swapUsed"]) / MB, swap_used / MB, "MB",
                   abs(int(values["mem.swapUsed"]) - swap_used) <= 64 * MB))
    checks.append(("mem.pressure", int(values["mem.pressure"]), int(sysctl("kern.memorystatus_vm_pressure_level")), "",
                   int(values["mem.pressure"]) == int(sysctl("kern.memorystatus_vm_pressure_level"))))
    checks.append(("cpu.cores", int(values["cpu.cores"]), int(sysctl("hw.ncpu")), "",
                   int(values["cpu.cores"]) == int(sysctl("hw.ncpu"))))
    checks.append(("cpu.performanceCores", int(values["cpu.performanceCores"]), int(sysctl("hw.perflevel0.logicalcpu")), "",
                   int(values["cpu.performanceCores"]) == int(sysctl("hw.perflevel0.logicalcpu"))))
    # Averages over the same seconds; the windows start a few ms apart.
    checks.append(("cpu.total (avg)", cpu_average * 100, result["top"] * 100, "%",
                   abs(cpu_average - result["top"]) <= (0.03 if LOAD else 0.10)))

    # Disk: same statfs as df; lifetime I/O against iostat -I.
    df = run("/bin/df", "-k", "/").splitlines()[-1].split()
    checks.append(("disk.total", int(values["disk.total"]) / MB, int(df[1]) * 1024 / MB, "MB",
                   int(values["disk.total"]) == int(df[1]) * 1024))
    checks.append(("disk.available", int(values["disk.available"]) / MB, int(df[3]) * 1024 / MB, "MB",
                   abs(int(values["disk.available"]) - int(df[3]) * 1024) <= 64 * MB))
    ours_io = (int(values["disk.readTotal"]) + int(values["disk.writtenTotal"])) / MB
    theirs_io = iostat_total_mb()
    checks.append(("disk.io since boot", ours_io, theirs_io, "MB", abs(ours_io - theirs_io) <= 256))

    # Network: counters per counted interface against netstat -ib.
    for key in sorted(k for k in values if k.startswith("net.") and k.endswith(".tx")):
        name = key[4:-3]
        link = links_after.get(name)
        if not link:
            continue
        for ours_key, theirs_key in ((f"net.{name}.rx", "ibytes"), (f"net.{name}.tx", "obytes")):
            mine = int(values[ours_key])
            theirs = link[theirs_key]
            checks.append((ours_key, mine / MB, theirs / MB, "MB", abs(mine - theirs) <= max(2 * MB, 0.01 * theirs)))
    route = re.search(r"interface: (\S+)", run("/sbin/route", "-n", "get", "default"))
    primary = route.group(1) if route else "-"
    checks.append(("net.primary", values["net.primary"], primary, "", values["net.primary"] == primary))
    ip = subprocess.run(["/usr/sbin/ipconfig", "getifaddr", primary], capture_output=True, text=True).stdout.strip() or "-"
    checks.append(("net.ipv4", values["net.ipv4"], ip, "", values["net.ipv4"] == ip))
    # VPN: tunnel interfaces that have an IPv4 address (not link-local), per ifconfig.
    tunnels, current = [], None
    for line in run("/sbin/ifconfig").splitlines():
        header = re.match(r"^(\S+?):", line)
        if header:
            current = header.group(1)
        inet = re.match(r"\s+inet (\S+)", line)
        if inet and current and current.startswith(("utun", "ipsec", "ppp", "tun", "tap")) \
                and not inet.group(1).startswith("169.254."):
            tunnels.append(f"{current}:{inet.group(1)}")
    vpn = ",".join(tunnels) or "-"
    checks.append(("net.vpn", values["net.vpn"], vpn, "", values["net.vpn"] == vpn))
    checks.append(("net.measurement", values["net.measurement"], "connections", "",
                   values["net.measurement"] == "connections"))
    # Fallback: interface counters. Inbound blind = outgoing packets without
    # any incoming packet on the counted interfaces.
    before = netstat_links()
    fallback = fields(run(BINARY, "--print-monitor", str(ROUNDS), "--interface-counters").strip().splitlines()[-1])
    after = netstat_links()
    counted = [n for n in after if n.startswith(("en", "pdp_ip")) and n in before]
    sent = sum(after[n]["opackets"] - before[n]["opackets"] for n in counted)
    received = sum(after[n]["ipackets"] - before[n]["ipackets"] for n in counted)
    expected_blind = sent >= 20 and received == 0
    is_blind = fallback["net.measurement"] == "interfacesInboundBlind"
    # The app judges only its own window (from its first reading), which is
    # shorter than this bracket: with little traffic it is still undecided
    # and then shows no download at all, never a false 0. That is correct.
    undecided = not is_blind and fallback.get("net.downRate") == "-"
    checks.append(("net.inbound blind", "yes" if is_blind else ("undecided" if undecided else "no"),
                   "yes" if expected_blind else "no", "",
                   is_blind == expected_blind or (is_blind and received == 0) or (expected_blind and undecided)))

    # Battery (only on Macs with one).
    if "power.charge" in values:
        pmset = pmset_battery()
        cycles, health = system_profiler_battery()
        checks.append(("power.charge", int(values["power.charge"]), pmset["charge"], "%",
                       abs(int(values["power.charge"]) - pmset["charge"]) <= 1))
        charging = pmset["state"] == "charging"
        checks.append(("power.charging", values["power.charging"], "1" if charging else "0", "",
                       (values["power.charging"] == "1") == charging))
        bracket = [p["minutes"] for p in (pmset_before, pmset) if p and p["minutes"] is not None]
        if bracket and values["power.minutes"] != "-":
            mine = int(values["power.minutes"])
            checks.append(("power.minutes", mine, pmset["minutes"] or bracket[0], "min",
                           min(bracket) - 3 <= mine <= max(bracket) + 3))
        checks.append(("power.cycles", values["power.cycles"], str(cycles), "", values["power.cycles"] == str(cycles)))
        # macOS rounds the full-charge/design ratio up, but shows a smoothed
        # value: the live full-charge capacity moves by a few mAh within
        # minutes (seen 4154-4164 mAh), so one point apart is possible.
        checks.append(("power.health", int(values["power.health"]), health, "%",
                       health is not None and abs(int(values["power.health"]) - health) <= 1))
        reference_power = ioreg_battery_power()
        if reference_power is not None and values["power.watts"] != "-":
            checks.append(("power.watts", float(values["power.watts"]), reference_power / 1000, "W",
                           abs(float(values["power.watts"]) - reference_power / 1000) <= 3))

    return report(checks)


def report(checks):
    failed = 0
    print(f"{'value':<22}{'MacHorus':>14}{'reference':>14}  result")
    for key, mine, theirs, unit, ok in checks:
        failed += not ok
        if mine is None or theirs is None or isinstance(mine, str) or isinstance(theirs, str):
            print(f"{key:<22}{str(mine):>14}{str(theirs):>14}  {'PASS' if ok else 'FAIL'}")
        else:
            print(f"{key:<22}{mine:>12.1f}{unit:>2}{theirs:>12.1f}{unit:>2}  {'PASS' if ok else 'FAIL'}"
                  if unit != "B" else f"{key:<22}{mine:>14,.0f}{theirs:>14,.0f}  {'PASS' if ok else 'FAIL'}")
    print("all values match" if failed == 0 else f"{failed} value(s) differ")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
