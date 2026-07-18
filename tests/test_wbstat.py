"""Tests for scripts/wbstat.py — the waybar CPU/RAM/temperature module.

Two things make this worth testing hard. It runs on a timer forever, so a bug
shows up as a bar that quietly lies rather than an error anyone sees. And its
sensor logic is written to travel between machines (Intel/AMD/ARM/VM) — exactly
the code paths the maintainer's own hardware never exercises. The fixtures below
fake sysfs, so a Ryzen box, an Intel box and a sensorless VM are all testable
from wherever the suite happens to run.
"""
import json
import pathlib

import pytest


@pytest.fixture
def fake_proc(monkeypatch, wbstat, tmp_path):
    """Point wbstat's Path() at fake /proc files, leaving other paths real."""
    files = {}

    def fake_path(p):
        return pathlib.Path(files.get(str(p), str(p)))

    def write(name: str, text: str) -> None:
        dest = tmp_path / name.replace("/", "_")
        dest.write_text(text)
        files[name] = str(dest)

    monkeypatch.setattr(wbstat, "Path", fake_path)
    return write


@pytest.fixture
def isolated_state(monkeypatch, wbstat, tmp_path):
    """Keep the rolling-history cache out of the real ~/.cache/hwe."""
    state = tmp_path / "state"
    monkeypatch.setattr(wbstat, "STATE", state)
    return state


@pytest.fixture
def fake_hwmon(monkeypatch, wbstat, tmp_path):
    """Build a fake /sys/class/hwmon tree: add_chip(name, {file: contents})."""
    root = tmp_path / "hwmon"
    root.mkdir()
    monkeypatch.setattr(wbstat, "HWMON", root)
    count = 0

    def add_chip(name: str, files: dict) -> pathlib.Path:
        nonlocal count
        d = root / f"hwmon{count}"
        count += 1
        d.mkdir()
        (d / "name").write_text(f"{name}\n")
        for fname, contents in files.items():
            (d / fname).write_text(f"{contents}\n")
        return d

    return add_chip


# ── The sparkline ─────────────────────────────────────────────────────────
def test_spark_maps_the_range_onto_blocks(wbstat):
    assert wbstat.spark([0]) == wbstat.BLOCKS[0]
    assert wbstat.spark([100]) == wbstat.BLOCKS[-1]
    assert len(wbstat.spark([0, 50, 100])) == 3


def test_spark_clamps_out_of_range_samples(wbstat):
    """A temp below the floor or above critical must not blow the index up."""
    assert wbstat.spark([-40]) == wbstat.BLOCKS[0]
    assert wbstat.spark([9999]) == wbstat.BLOCKS[-1]


def test_spark_rises_monotonically(wbstat):
    out = wbstat.spark([0, 25, 50, 75, 100])
    indices = [wbstat.BLOCKS.index(ch) for ch in out]
    assert indices == sorted(indices)


def test_spark_of_an_empty_history_is_empty(wbstat):
    assert wbstat.spark([]) == ""


def test_spark_handles_a_degenerate_range(wbstat):
    """lo == hi would divide by zero without the epsilon guard."""
    assert len(wbstat.spark([50, 50], lo=50, hi=50)) == 2


# ── CPU ───────────────────────────────────────────────────────────────────
def test_cpu_first_poll_reports_zero(wbstat, fake_proc):
    """With no previous counters there is no delta to measure — do not guess."""
    fake_proc("/proc/stat", "cpu  100 0 100 700 100 0 0 0 0 0\nintr 1\n")
    state = {}
    assert wbstat.cpu_pct(state) == 0.0
    assert state["prev"] == [1000, 800]


def test_cpu_busy_from_the_delta_between_polls(wbstat, fake_proc):
    fake_proc("/proc/stat", "cpu  100 0 100 700 100 0 0 0 0 0\n")
    state = {}
    wbstat.cpu_pct(state)
    # Second poll: +1000 total, of which +800 idle -> 20% busy.
    fake_proc("/proc/stat", "cpu  200 0 200 1400 200 0 0 0 0 0\n")
    assert wbstat.cpu_pct(state) == pytest.approx(20.0)


def test_cpu_fully_idle_reads_zero(wbstat, fake_proc):
    fake_proc("/proc/stat", "cpu  0 0 0 1000 0 0 0 0 0 0\n")
    state = {}
    wbstat.cpu_pct(state)
    fake_proc("/proc/stat", "cpu  0 0 0 2000 0 0 0 0 0 0\n")
    assert wbstat.cpu_pct(state) == pytest.approx(0.0)


def test_cpu_fully_busy_reads_one_hundred(wbstat, fake_proc):
    fake_proc("/proc/stat", "cpu  0 0 0 1000 0 0 0 0 0 0\n")
    state = {}
    wbstat.cpu_pct(state)
    fake_proc("/proc/stat", "cpu  1000 0 0 1000 0 0 0 0 0 0\n")
    assert wbstat.cpu_pct(state) == pytest.approx(100.0)


def test_cpu_survives_identical_consecutive_polls(wbstat, fake_proc):
    """Polling faster than the clock ticks gives dt == 0 — must not divide by it."""
    fake_proc("/proc/stat", "cpu  100 0 100 700 100 0 0 0 0 0\n")
    state = {}
    wbstat.cpu_pct(state)
    assert wbstat.cpu_pct(state) == 0.0


def test_cpu_counts_iowait_as_idle(wbstat, fake_proc):
    """iowait is the CPU waiting, not working — folding it into busy would lie."""
    fake_proc("/proc/stat", "cpu  0 0 0 500 500 0 0 0 0 0\n")
    state = {}
    wbstat.cpu_pct(state)
    fake_proc("/proc/stat", "cpu  0 0 0 500 1500 0 0 0 0 0\n")
    assert wbstat.cpu_pct(state) == pytest.approx(0.0)


# ── Memory ────────────────────────────────────────────────────────────────
def test_mem_uses_available_not_free(wbstat, fake_proc):
    """MemAvailable accounts for reclaimable cache; MemFree would read ~100%."""
    fake_proc("/proc/meminfo", "MemTotal:  1000 kB\nMemFree:   10 kB\nMemAvailable: 250 kB\n")
    assert wbstat.mem_pct({}) == pytest.approx(75.0)


def test_mem_without_available_falls_back_to_zero_used(wbstat, fake_proc):
    fake_proc("/proc/meminfo", "MemTotal:  1000 kB\nMemFree: 10 kB\n")
    assert wbstat.mem_pct({}) == pytest.approx(0.0)


# ── Temperature: sensor discovery ─────────────────────────────────────────
def test_no_sensor_at_all_returns_none(wbstat, fake_hwmon):
    assert wbstat.find_cpu_temp() is None


def test_unrelated_chips_are_ignored(wbstat, fake_hwmon):
    """A drive or battery sensor is not a CPU temperature."""
    fake_hwmon("nvme", {"temp1_input": "45000"})
    assert wbstat.find_cpu_temp() is None


def test_intel_package_die_is_preferred_over_a_core(wbstat, fake_hwmon):
    fake_hwmon("coretemp", {
        "temp1_input": "40000", "temp1_label": "Core 0",
        "temp2_input": "55000", "temp2_label": "Package id 0", "temp2_crit": "100000",
    })
    celsius, crit, chip = wbstat.find_cpu_temp()
    assert (celsius, crit, chip) == (55.0, 100.0, "coretemp")


def test_amd_prefers_tdie_over_tctl(wbstat, fake_hwmon):
    """Tctl carries a vendor offset; Tdie is the real junction temperature."""
    fake_hwmon("k10temp", {
        "temp1_input": "70000", "temp1_label": "Tctl",
        "temp2_input": "60000", "temp2_label": "Tdie", "temp2_crit": "95000",
    })
    celsius, crit, chip = wbstat.find_cpu_temp()
    assert (celsius, crit, chip) == (60.0, 95.0, "k10temp")


def test_amd_falls_back_to_tctl_when_tdie_is_absent(wbstat, fake_hwmon):
    fake_hwmon("k10temp", {"temp1_input": "70000", "temp1_label": "Tctl"})
    celsius, _crit, chip = wbstat.find_cpu_temp()
    assert (celsius, chip) == (70.0, "k10temp")


def test_a_real_cpu_chip_beats_the_acpi_proxy(wbstat, fake_hwmon):
    """acpitz is a chassis sensor and a poor CPU proxy — last resort only."""
    fake_hwmon("acpitz", {"temp1_input": "40000"})
    fake_hwmon("coretemp", {"temp1_input": "55000", "temp1_label": "Package id 0"})
    _celsius, _crit, chip = wbstat.find_cpu_temp()
    assert chip == "coretemp"


def test_acpitz_is_used_when_it_is_all_there_is(wbstat, fake_hwmon):
    """The common VM case: no die sensor passed through, one ACPI zone."""
    fake_hwmon("acpitz", {"temp1_input": "42000"})
    celsius, crit, chip = wbstat.find_cpu_temp()
    assert (celsius, chip) == (42.0, "acpitz")
    assert crit == wbstat.TEMP_CRIT_FALLBACK


def test_an_unlabelled_chip_uses_its_first_reading(wbstat, fake_hwmon):
    fake_hwmon("cpu_thermal", {"temp1_input": "48000"})
    celsius, _crit, chip = wbstat.find_cpu_temp()
    assert (celsius, chip) == (48.0, "cpu_thermal")


def test_max_stands_in_for_a_missing_crit(wbstat, fake_hwmon):
    fake_hwmon("coretemp", {
        "temp1_input": "50000", "temp1_label": "Package id 0", "temp1_max": "84000",
    })
    _celsius, crit, _chip = wbstat.find_cpu_temp()
    assert crit == 84.0


def test_critical_falls_back_when_the_chip_declares_none(wbstat, fake_hwmon):
    fake_hwmon("coretemp", {"temp1_input": "50000", "temp1_label": "Package id 0"})
    _celsius, crit, _chip = wbstat.find_cpu_temp()
    assert crit == wbstat.TEMP_CRIT_FALLBACK


def test_a_chip_with_no_readable_input_is_skipped(wbstat, fake_hwmon):
    """A present-but-unreadable sensor must fall through, not crash the bar."""
    fake_hwmon("coretemp", {"temp1_input": "garbage", "temp1_label": "Package id 0"})
    fake_hwmon("acpitz", {"temp1_input": "42000"})
    result = wbstat.find_cpu_temp()
    assert result is not None and result[2] == "acpitz"


# ── Temperature: the emitted module ───────────────────────────────────────
def test_probe_succeeds_when_a_sensor_exists(wbstat, fake_hwmon, isolated_state):
    fake_hwmon("coretemp", {"temp1_input": "50000", "temp1_label": "Package id 0"})
    assert wbstat.temp_json(["temp", "--probe"]) == 0


def test_probe_fails_when_no_sensor_exists(wbstat, fake_hwmon, isolated_state):
    """exec-if: a non-zero probe is how the module hides itself in a VM."""
    assert wbstat.temp_json(["temp", "--probe"]) == 1


def test_probe_prints_nothing(wbstat, fake_hwmon, isolated_state, capsys):
    fake_hwmon("coretemp", {"temp1_input": "50000", "temp1_label": "Package id 0"})
    wbstat.temp_json(["temp", "--probe"])
    assert capsys.readouterr().out == ""


def test_temp_percentage_scales_to_the_chips_own_critical(
    wbstat, fake_hwmon, isolated_state, capsys
):
    """Halfway between floor (30°C) and this chip's crit (90°C) is 50%."""
    fake_hwmon("k10temp", {"temp1_input": "60000", "temp1_label": "Tdie", "temp1_crit": "90000"})
    wbstat.temp_json(["temp"])
    assert json.loads(capsys.readouterr().out)["percentage"] == 50


def test_temp_names_the_chip_in_the_tooltip(wbstat, fake_hwmon, isolated_state, capsys):
    fake_hwmon("k10temp", {"temp1_input": "60000", "temp1_label": "Tdie", "temp1_crit": "90000"})
    wbstat.temp_json(["temp"])
    tooltip = json.loads(capsys.readouterr().out)["tooltip"]
    assert "60°C" in tooltip and "k10temp" in tooltip


def test_temp_percentage_is_clamped_to_the_bar_range(
    wbstat, fake_hwmon, isolated_state, capsys
):
    """Below the floor and above critical must still be a valid percentage."""
    fake_hwmon("acpitz", {"temp1_input": "10000"})  # 10°C, below TEMP_FLOOR
    wbstat.temp_json(["temp"])
    assert json.loads(capsys.readouterr().out)["percentage"] == 0


@pytest.mark.parametrize(
    ("milli", "expected"),
    [
        (40000, ""),           # 40°C of 100 -> quiet
        (65000, "busy"),       # >= 60%
        (85000, "warning"),    # >= 80%
        (95000, "critical"),   # >= 92%
    ],
)
def test_temp_class_thresholds(wbstat, fake_hwmon, isolated_state, capsys, milli, expected):
    fake_hwmon("coretemp", {
        "temp1_input": str(milli), "temp1_label": "Package id 0", "temp1_crit": "100000",
    })
    wbstat.temp_json(["temp"])
    assert json.loads(capsys.readouterr().out)["class"] == expected


def test_temp_without_a_sensor_says_so_rather_than_reading_a_lie(
    wbstat, fake_hwmon, isolated_state, capsys
):
    assert wbstat.temp_json(["temp"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["text"] == "" and "no CPU temperature sensor" in out["tooltip"]


# ── The module contract waybar consumes ───────────────────────────────────
@pytest.mark.parametrize("kind", ["cpu", "mem"])
def test_module_emits_the_waybar_json_contract(wbstat, fake_proc, isolated_state, capsys, kind):
    fake_proc("/proc/stat", "cpu  100 0 100 700 100 0 0 0 0 0\n")
    fake_proc("/proc/meminfo", "MemTotal: 1000 kB\nMemAvailable: 250 kB\n")
    assert wbstat.main([kind]) == 0
    out = json.loads(capsys.readouterr().out)
    assert set(out) == {"text", "percentage", "tooltip", "class"}
    # The bar draws the glyph from `percentage`; any text here would be dead weight.
    assert out["text"] == ""
    assert isinstance(out["percentage"], int)


def test_an_unknown_kind_is_rejected(wbstat):
    with pytest.raises(SystemExit):
        wbstat.main(["disk"])


def test_kind_defaults_to_cpu(wbstat, fake_proc, isolated_state, capsys):
    fake_proc("/proc/stat", "cpu  100 0 100 700 100 0 0 0 0 0\n")
    assert wbstat.main([]) == 0
    assert "CPU" in json.loads(capsys.readouterr().out)["tooltip"]


# ── Rolling history ───────────────────────────────────────────────────────
def test_history_persists_across_polls_and_is_capped(
    wbstat, fake_proc, isolated_state, capsys
):
    fake_proc("/proc/meminfo", "MemTotal: 1000 kB\nMemAvailable: 250 kB\n")
    for _ in range(wbstat.HIST + 4):
        wbstat.main(["mem"])
        capsys.readouterr()
    hist = wbstat._load("mem")["hist"]
    assert len(hist) == wbstat.HIST, "history must not grow without bound"
    assert hist[-1] == pytest.approx(75.0)


def test_load_tolerates_a_corrupt_state_file(wbstat, isolated_state):
    """The cache is disposable — a truncated write must not break the bar."""
    isolated_state.mkdir(parents=True)
    (isolated_state / "cpu.json").write_text("{not json")
    assert wbstat._load("cpu") == {}


def test_load_of_a_missing_state_file_is_empty(wbstat, isolated_state):
    assert wbstat._load("cpu") == {}


def test_save_creates_the_cache_directory(wbstat, isolated_state):
    wbstat._save("cpu", {"hist": [1.0]})
    assert wbstat._load("cpu") == {"hist": [1.0]}


def test_save_to_an_unwritable_location_is_swallowed(wbstat, monkeypatch, tmp_path):
    """Waybar polls forever; a read-only cache must not become an error storm."""
    blocked = tmp_path / "file-in-the-way"
    blocked.write_text("not a directory")
    monkeypatch.setattr(wbstat, "STATE", blocked / "state")
    wbstat._save("cpu", {"hist": [1.0]})  # must not raise
