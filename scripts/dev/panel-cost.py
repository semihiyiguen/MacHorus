#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 MacHorus contributors
"""Exact CPU cost of the real panel: opening, one sampling round, closing
and being closed. Opens the real popover (it shows on screen; do not click
for about 45 s), toggles it every 6 s and reads the app's CPU time every
100 ms with scripts/dev/cpu-trace.swift. top's 1-second percentages are too
coarse for this. With --steady the panel stays open and one round is the
average over 30 s (less noise when comparing two versions). Usage:
    python3 -I scripts/dev/panel-cost.py [--steady] [--tab overview|monitor|settings] [path/to/MacHorus] [extra app arguments]
"""

import os
import subprocess
import sys
import time

RAW = sys.argv[1:]
TAB = RAW[RAW.index("--tab") + 1] if "--tab" in RAW else "monitor"
if "--tab" in RAW:
    del RAW[RAW.index("--tab"):RAW.index("--tab") + 2]
ARGS = [arg for arg in RAW if arg != "--steady"]
STEADY = "--steady" in sys.argv
BINARY = ARGS[0] if ARGS else "build/MacHorus.app/Contents/MacOS/MacHorus"
EXTRA = ARGS[1:]


def tool():
    source, binary = "scripts/dev/cpu-trace.swift", ".build/dev/cpu-trace"
    if not os.path.exists(binary) or os.path.getmtime(binary) < os.path.getmtime(source):
        os.makedirs(".build/dev", exist_ok=True)
        subprocess.run(["/usr/bin/swiftc", "-O", source, "-o", binary], check=True, capture_output=True)
    return binary


def steady(trace_tool):
    """Panel open once; average CPU per 2-second round over 30 s."""
    subprocess.run(["/usr/bin/pkill", "-x", "MacHorus"])
    time.sleep(1)
    app = subprocess.Popen([BINARY, "-debug.showPanel", TAB, *EXTRA], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
    time.sleep(6)
    trace = subprocess.run([trace_tool, str(app.pid), "30", "100"], capture_output=True, text=True).stdout
    app.kill()
    total = sum(float(line.split()[1]) for line in trace.splitlines())
    print(f"steady: {total / 15:.1f} ms per 2 s round ({total / 30 / 10:.2f} % of one core)")


def main():
    trace_tool = tool()
    if STEADY:
        return steady(trace_tool)
    subprocess.run(["/usr/bin/pkill", "-x", "MacHorus"])
    time.sleep(1)
    app = subprocess.Popen([BINARY, "-debug.showPanel", TAB, "-debug.showPanelDelay", "4", "-debug.panelCycle", "6",
                            *EXTRA], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.3)
    trace = subprocess.run([trace_tool, str(app.pid), "44", "100"], capture_output=True, text=True).stdout
    app.kill()
    rows = [tuple(map(float, line.split())) for line in trace.splitlines()]

    def window(start, end):
        return sum(step for at, step, _ in rows if start <= at < end)

    # The first burst after launch is the first opening; then every 12 s.
    first = next(at for at, step, _ in rows if at > 1.0 and step > 10) - 0.2
    print(f"{'opening':<10}{'open 1.5 s':>12}{'per round':>12}{'close 1 s':>12}{'closed 4 s':>12}  (CPU ms)")
    for index in range(3):
        start = first + 12 * index
        print(f"{index + 1:<10}{window(start, start + 1.5):>12.1f}{window(start + 1.6, start + 5.6) / 2:>12.1f}"
              f"{window(start + 5.8, start + 6.8):>12.1f}{window(start + 7.8, start + 11.8):>12.2f}")
    print(f"launch before opening: {window(0, first):.1f} ms")


if __name__ == "__main__":
    sys.exit(main())
