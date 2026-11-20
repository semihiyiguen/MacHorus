#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 MacHorus contributors
"""Compares what the tools page shows with the system's own tools:
pending updates (the same plist files, parsed independently), listening
ports (lsof) and microphones (system_profiler). Prints one line per check
and exits non-zero on a mismatch. Usage:
    python3 -I scripts/dev/verify-tools.py [path/to/MacHorus]
"""

import os
import plistlib
import re
import subprocess
import sys
import time

BINARY = sys.argv[1] if len(sys.argv) > 1 else "build/MacHorus.app/Contents/MacOS/MacHorus"
CHECKS = []


def run(*command):
    return subprocess.run(command, capture_output=True, text=True).stdout


def ours(flag):
    return [line.split("=", 1) for line in run(BINARY, flag).splitlines() if "=" in line]


def check(name, mine, theirs, ok=None, secret=False):
    passed = (mine == theirs) if ok is None else ok
    shown = ("(hidden)", "(hidden)") if secret else (mine, theirs)
    CHECKS.append(passed)
    print(f"{'PASS' if passed else 'FAIL'}  {name:22s} {str(shown[0])[:40]:40s} {str(shown[1])[:40]}")


def updates():
    lines = ours("--print-updates")
    munki = sorted(value for key, value in lines if key == "munki")
    apple = sorted(value for key, value in lines if key == "apple")
    expected = []
    info_path = "/Library/Managed Installs/InstallInfo.plist"
    if os.path.exists(info_path):
        info = plistlib.load(open(info_path, "rb"))
        for key in ("managed_installs", "managed_updates"):
            for item in info.get(key, []):
                if item.get("installed") is True:
                    continue
                restart = {"RequireRestart": "required", "RecommendRestart": "recommended",
                           "RequireLogout": "logout"}.get(item.get("RestartAction"), "none")
                name = item.get("display_name") or item.get("name")
                expected.append(f"{name}|{item.get('version_to_install', '-')}|install|{restart}")
        for item in info.get("removals", []):
            if item.get("installed") is False:
                continue
            name = item.get("display_name") or item.get("name")
            expected.append(f"{name}|-|remove|{item.get('RestartAction') and 'required' or 'none'}")
    check("munki pending", len(munki), len(expected), munki == sorted(expected))
    preferences = "/Library/Preferences/ManagedInstalls.plist"
    if os.path.exists(preferences):
        last = plistlib.load(open(preferences, "rb")).get("LastCheckDate")
        mine = dict(lines).get("lastCheck", "-")
        theirs = str(int(last.replace(tzinfo=__import__("datetime").timezone.utc).timestamp())) if last else "-"
        check("munki last check", mine, theirs)
    software = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
    recommended = plistlib.load(open(software, "rb")).get("RecommendedUpdates", []) if os.path.exists(software) else []
    expected_apple = sorted(f"{u.get('Display Name')}|{u.get('Display Version', '-')}" for u in recommended)
    check("macOS updates", len(apple), len(expected_apple), apple == expected_apple)


def ports():
    mine = sorted((int(p), int(pid)) for p, pid, *_ in (v.split("|") for k, v in ours("--print-ports") if k == "port"))
    theirs = set()
    for line in run("/usr/sbin/lsof", "-a", "-nP", "-iTCP", "-sTCP:LISTEN", "-u", str(os.getuid())).splitlines()[1:]:
        parts = line.split()
        port = re.search(r":(\d+)$", parts[8]) if len(parts) > 8 else None
        if port:
            theirs.add((int(port.group(1)), int(parts[1])))
    check("listening ports", len(mine), len(theirs), set(mine) == theirs)


def microphones():
    mine = sorted(value.split("|")[1] for key, value in ours("--print-microphones") if key == "microphone")
    audio = run("/usr/sbin/system_profiler", "SPAudioDataType")
    theirs, name = [], None
    for line in audio.splitlines():
        header = re.match(r"^        (\S.*):$", line)
        if header:
            name = header.group(1)
        if name and re.match(r"^\s+Input Channels: \d+", line):
            theirs.append(name)
    # Virtual devices (e.g. a meeting app's sharing device) are not microphones.
    virtual = set()
    for line in audio.splitlines():
        header = re.match(r"^        (\S.*):$", line)
        if header:
            name = header.group(1)
        if name and re.match(r"^\s+Transport: Virtual|^\s+Transport: Aggregate", line):
            virtual.add(name)
    check("microphones", mine, sorted(set(theirs) - virtual))


def audio():
    """A process that plays must show up with running output (Core Audio
    process objects); a quiet system sound is played for it."""
    player = subprocess.Popen(["/usr/bin/afplay", "-v", "0.02", "/System/Library/Sounds/Submarine.aiff"])
    time.sleep(0.3)
    lines = [v.split("|") for k, v in ours("--print-audio") if k == "audio"]
    player.wait()
    entry = next((parts for parts in lines if int(parts[0]) == player.pid), None)
    check("audio output of afplay", entry[3] if entry else "missing", "output=true",
          bool(entry) and entry[3] == "output=true")


def main():
    audio()
    updates()
    ports()
    microphones()
    print("all values match" if all(CHECKS) else "MISMATCH")
    return 0 if all(CHECKS) else 1


if __name__ == "__main__":
    sys.exit(main())
