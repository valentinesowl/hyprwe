#!/usr/bin/env python3
"""wbstat.py — CPU / RAM / temperature readings for the HWE waybar.

Emits one line of Waybar custom-module JSON. The BAR gets only a percentage:
Waybar turns it into a morphing glyph itself (`format-icons`, low -> high in
config.jsonc), keeping this side of the bar glyph-only like every other
indicator. The precise reading — the exact value plus a rolling sparkline of the
recent trend (▁▂▃▄▅▆▇█) — goes to the tooltip. State (previous CPU counters +
that history) lives in ~/.cache/hwe/wbstat so successive polls form a trend.

Usage (from waybar config, return-type json):  wbstat.py <cpu|mem|temp>
                                               wbstat.py temp --probe
"""
import json
import os
import sys
from pathlib import Path

BLOCKS = "▁▂▃▄▅▆▇█"
HIST = 8  # how many samples the sparkline shows

# Load -> CSS class; the bar stays quiet until there is something to say.
# (style.css paints these: fg_normal -> fg_bright -> orange -> red.)
BUSY, WARNING, CRITICAL = 40, 70, 90

HWMON = Path("/sys/class/hwmon")

# CPU temperature sensors, best first — matched by the chip's NAME, which is
# stable, never by hwmon number or path. /sys/class/hwmon/hwmonN numbering is
# assigned in probe order and shifts between boots, and AMD's sensor hangs off a
# PCI address that differs across Ryzen/Threadripper/EPYC — so no list of paths
# can travel between machines, while these names do.
#
# Every driver here ships with the kernel (CONFIG_SENSORS_*=m in the `linux`
# package) and autoloads from the hardware's own alias — coretemp off the CPU
# modalias, k10temp off a PCI id — so nothing has to be installed for a sensor
# to appear. Where none of them exists (a VM with no thermal passthrough), the
# module hides itself instead: see --probe / exec-if in config.jsonc.
#
#   coretemp: Intel. "Package id 0" is the die; temp2.. are the individual cores
#   k10temp:  AMD. Tdie is the real junction temp, Tctl the same with an offset
#   acpitz:   an ACPI chassis sensor — a poor CPU proxy, but often a VM's only one
CPU_CHIPS = (
    ("coretemp",    ("Package id 0",)),
    ("k10temp",     ("Tdie", "Tctl")),
    ("zenpower",    ("Tdie", "Tctl")),   # AUR driver some Ryzen owners prefer
    ("cpu_thermal", ()),                 # ARM SoCs
    ("acpitz",      ()),                 # last resort (VMs, some laptops)
)

# The icon scale runs from "room temperature" to the sensor's OWN critical
# point, so one config reads right on a 100°C Intel die and a 95°C Ryzen alike
# instead of hardcoding a Celsius ramp that suits one vendor.
TEMP_FLOOR = 30.0
TEMP_CRIT_FALLBACK = 100.0
# Class thresholds as a fraction of that critical point, for the same reason.
TEMP_BUSY, TEMP_WARNING, TEMP_CRITICAL = 0.60, 0.80, 0.92

STATE = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "hwe" / "wbstat"


def _load(kind):
    try:
        return json.loads((STATE / f"{kind}.json").read_text())
    except Exception:
        return {}


def _save(kind, data):
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        (STATE / f"{kind}.json").write_text(json.dumps(data))
    except Exception:
        pass


def cpu_pct(state):
    """CPU busy% since the previous poll, from /proc/stat deltas."""
    parts = [int(x) for x in Path("/proc/stat").read_text().split("\n")[0].split()[1:]]
    idle = parts[3] + parts[4]  # idle + iowait
    total = sum(parts)
    prev = state.get("prev")
    state["prev"] = [total, idle]
    if not prev:
        return 0.0
    dt, di = total - prev[0], idle - prev[1]
    return 100.0 * (dt - di) / dt if dt > 0 else 0.0


def mem_pct(_state):
    info = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        k, _, v = line.partition(":")
        info[k] = int(v.split()[0])  # kB
    total = info.get("MemTotal", 1)
    avail = info.get("MemAvailable", total)
    return 100.0 * (total - avail) / total


def _read_int(path):
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def _sibling(inp, suffix):
    """temp1_input -> temp1_<suffix> (its label, critical point, ...)."""
    return inp.with_name(inp.name.replace("_input", suffix))


def find_cpu_temp():
    """Best available CPU sensor as (celsius, critical, chip), or None.

    Walks CPU_CHIPS in priority order, matching the chip NAME, then picks the
    reading that IS the die (by label) rather than whatever landed on temp1.
    """
    chips = {}
    for d in sorted(HWMON.glob("hwmon*")):
        name = (d / "name")
        if name.exists():
            chips.setdefault(name.read_text().strip(), d)

    for chip, preferred in CPU_CHIPS:
        d = chips.get(chip)
        if d is None:
            continue
        inputs = sorted(d.glob("temp*_input"))
        if not inputs:
            continue
        chosen = None
        for want in preferred:
            for inp in inputs:
                label = _sibling(inp, "_label")
                if label.exists() and label.read_text().strip() == want:
                    chosen = inp
                    break
            if chosen:
                break
        chosen = chosen or inputs[0]      # unlabelled chip: temp1 is the die
        milli = _read_int(chosen)
        if milli is None:
            continue
        crit = next((_read_int(_sibling(chosen, s)) for s in ("_crit", "_max")
                     if _read_int(_sibling(chosen, s))), None)
        return milli / 1000.0, (crit / 1000.0 if crit else TEMP_CRIT_FALLBACK), chip
    return None


def spark(hist, lo=0.0, hi=100.0):
    span = max(hi - lo, 1e-6)
    return "".join(
        BLOCKS[max(0, min(len(BLOCKS) - 1, int((p - lo) / span * len(BLOCKS))))]
        for p in hist
    )


def temp_json(argv):
    """The temperature module. Returns an exit code; prints JSON unless probing."""
    found = find_cpu_temp()
    if "--probe" in argv:
        # exec-if: no CPU sensor (a VM with nothing passed through) -> Waybar
        # never runs the module and the glyph is simply absent, rather than
        # sitting there reading a lie.
        return 0 if found else 1
    if not found:
        print(json.dumps({"text": "", "tooltip": "no CPU temperature sensor"}))
        return 0

    celsius, crit, chip = found
    state = _load("temp")
    hist = [*state.get("hist", []), round(celsius, 1)][-HIST:]
    state["hist"] = hist
    _save("temp", state)

    pct = 100.0 * (celsius - TEMP_FLOOR) / max(crit - TEMP_FLOOR, 1e-6)
    cls = ("critical" if celsius >= TEMP_CRITICAL * crit
           else "warning" if celsius >= TEMP_WARNING * crit
           else "busy" if celsius >= TEMP_BUSY * crit else "")
    print(json.dumps({
        "text": "",
        "percentage": round(max(0.0, min(100.0, pct))),
        # The chip is named on purpose: it is the one thing you want to see when
        # this reads oddly on an unfamiliar machine.
        "tooltip": f"CPU: {celsius:.0f}°C   {spark(hist, TEMP_FLOOR, crit)}"
                   f"   ({chip}, critical {crit:.0f}°C)",
        "class": cls,
    }))
    return 0


def main(argv):
    kind = argv[0] if argv else "cpu"
    if kind not in ("cpu", "mem", "temp"):
        sys.exit("wbstat.py: kind must be cpu, mem or temp")
    if kind == "temp":
        return temp_json(argv)

    state = _load(kind)
    pct = cpu_pct(state) if kind == "cpu" else mem_pct(state)
    hist = [*state.get("hist", []), round(pct, 1)][-HIST:]
    state["hist"] = hist
    _save(kind, state)

    cls = ("critical" if pct >= CRITICAL else "warning" if pct >= WARNING
           else "busy" if pct >= BUSY else "")
    label = "CPU" if kind == "cpu" else "RAM"
    print(json.dumps({
        # No text: config.jsonc formats these as "{icon}" and picks the glyph
        # from `percentage`, so anything here would never reach the bar anyway.
        "text": "",
        "percentage": round(pct),
        "tooltip": f"{label}: {pct:.0f}%   {spark(hist)}",
        "class": cls,
    }))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]) or 0)
    except SystemExit:
        raise
    except Exception as e:  # never let the bar break on a transient read error
        print(json.dumps({"text": "", "tooltip": f"wbstat: {e}"}))
