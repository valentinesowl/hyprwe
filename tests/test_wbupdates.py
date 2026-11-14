"""Package update parsing and Waybar payload tests."""
import json
from types import SimpleNamespace


def completed(stdout="", stderr="", code=0):
    return SimpleNamespace(stdout=stdout, stderr=stderr, returncode=code)


def test_parse_checkupdates_reads_only_update_rows(wbupdates):
    text = "linux 6.1 -> 6.2\nnot an update\nfirefox 100.0 -> 101.0\n"
    assert wbupdates.parse_checkupdates(text) == [
        ("linux", "6.1", "6.2"), ("firefox", "100.0", "101.0"),
    ]


def test_parse_apt_reads_upgrades_with_installed_versions(wbupdates):
    text = (
        "Reading package lists...\n"
        "Inst linux-image [6.1] (6.2 Ubuntu:26.04/stable [amd64])\n"
        "Inst new-dependency (1.0 Ubuntu:26.04/stable [amd64])\n"
        "Conf linux-image (6.2 Ubuntu:26.04/stable [amd64])\n"
    )
    assert wbupdates.parse_apt(text) == [("linux-image", "6.1", "6.2")]


def test_arch_collection_uses_checkupdates_without_sync_flags(wbupdates):
    calls = []

    def run(cmd, **kwargs):
        calls.append((cmd, kwargs))
        return completed("hyprland 1.0 -> 1.1\n")

    updates = wbupdates.collect(run=run, which=lambda name: "/usr/bin/checkupdates")
    assert updates == [("hyprland", "1.0", "1.1")]
    assert calls[0][0] == ["checkupdates", "--nocolor"]
    assert calls[0][1]["check"] is False


def test_checkupdates_exit_two_means_no_updates(wbupdates):
    updates = wbupdates.collect(
        run=lambda *args, **kwargs: completed(code=2),
        which=lambda name: "/usr/bin/checkupdates",
    )
    assert updates == []


def test_ubuntu_collection_is_a_read_only_simulation(wbupdates):
    calls = []

    def run(cmd, **kwargs):
        calls.append(cmd)
        return completed("Inst bash [5.2] (5.3 Ubuntu:26.04 [amd64])\n")

    updates = wbupdates.collect(
        run=run, which=lambda name: "/usr/bin/apt-get" if name == "apt-get" else None
    )
    assert updates == [("bash", "5.2", "5.3")]
    assert calls == [["apt-get", "-s", "upgrade"]]


def test_zero_updates_hide_the_badge(wbupdates):
    assert wbupdates.payload([])["text"] == ""
    assert wbupdates.payload([])["class"] == "empty"


def test_icon_size_uses_pango_units_instead_of_invalid_css_pixels(wbupdates):
    assert wbupdates.ICON_MARKUP == "<span size='8448'>󰮯</span>"


def test_badge_counts_updates_and_escapes_tooltip(wbupdates):
    updates = [("a&b", "1", "2"), ("c<d", "3", "4")]
    result = wbupdates.payload(updates)
    assert result["text"] == f"{wbupdates.ICON_MARKUP} 2"
    assert "a&amp;b: 1 → 2" in result["tooltip"]
    assert "c&lt;d: 3 → 4" in result["tooltip"]


def test_tooltip_truncates_a_long_package_list(wbupdates):
    updates = [(f"package-{i}", "1", "2") for i in range(25)]
    result = wbupdates.payload(updates)
    assert "package-19" in result["tooltip"]
    assert "package-20:" not in result["tooltip"]
    assert "and 5 more" in result["tooltip"]


def test_collection_errors_become_a_visible_error_payload(
    wbupdates, monkeypatch, capsys, tmp_path,
):
    def fail():
        raise RuntimeError("mirror unavailable")

    monkeypatch.setattr(wbupdates, "state_path", lambda: tmp_path / "updates.json")
    monkeypatch.setattr(wbupdates, "collect", fail)
    assert wbupdates.main() == 0
    result = json.loads(capsys.readouterr().out)
    assert result["class"] == "error"
    assert result["text"] == f"{wbupdates.ICON_MARKUP} !"
    assert "mirror unavailable" in result["tooltip"]


def test_poll_reuses_the_cached_result_for_an_hour(wbupdates, monkeypatch, capsys, tmp_path):
    checks = []

    monkeypatch.setattr(wbupdates, "state_path", lambda: tmp_path / "updates.json")
    monkeypatch.setattr(wbupdates, "package_database_stamp", lambda: (("db", 1),))
    monkeypatch.setattr(wbupdates, "collect", lambda: checks.append("check") or [("a", "1", "2")])
    monkeypatch.setattr(wbupdates.time, "time", lambda: 100.0)
    wbupdates.main()
    monkeypatch.setattr(wbupdates.time, "time", lambda: 100.0 + wbupdates.CHECK_INTERVAL - 1)
    wbupdates.main()
    assert checks == ["check"]
    assert len(capsys.readouterr().out.splitlines()) == 2

    monkeypatch.setattr(wbupdates.time, "time", lambda: 100.0 + wbupdates.CHECK_INTERVAL)
    wbupdates.main()
    assert checks == ["check", "check"]


def test_poll_rechecks_as_soon_as_the_package_database_changes(
    wbupdates, monkeypatch, capsys, tmp_path,
):
    checks = []
    stamp = {"value": ("db", 1)}

    monkeypatch.setattr(wbupdates, "state_path", lambda: tmp_path / "updates.json")
    monkeypatch.setattr(wbupdates, "package_database_stamp", lambda: (stamp["value"],))
    monkeypatch.setattr(wbupdates, "collect", lambda: checks.append("check") or [])
    monkeypatch.setattr(wbupdates.time, "time", lambda: 100.0)
    wbupdates.main()
    wbupdates.main()
    assert checks == ["check"]

    stamp["value"] = ("db", 2)
    wbupdates.main()
    assert checks == ["check", "check"]
    assert len(capsys.readouterr().out.splitlines()) == 3


def test_package_database_stamp_uses_file_mtime(wbupdates, tmp_path):
    database = tmp_path / "status"
    database.write_text("installed")
    assert wbupdates.package_database_stamp((database,)) == (
        (str(database), database.stat().st_mtime_ns),
    )
