"""Tests for scripts/wbmerge.py — the Waybar override deep-merge.

Bar composition is a user concern layered over the generated config on every
apply. The merge has two moving parts that are easy to get subtly wrong: a JSONC
comment stripper that must respect strings, and a deep-merge whose rules (objects
recurse, everything else replaces, null deletes) are the whole contract a user
relies on. Both are pinned here so an edit can't quietly change what a user's
override does to their bar.
"""
import json


# ── strip_jsonc: comments go, but never inside a string ────────────────────
def test_line_comments_are_removed(wbmerge):
    assert json.loads(wbmerge.strip_jsonc('{"a": 1} // trailing')) == {"a": 1}


def test_block_comments_are_removed(wbmerge):
    assert json.loads(wbmerge.strip_jsonc('{/* x */ "a": 1}')) == {"a": 1}


def test_a_double_slash_inside_a_string_survives(wbmerge):
    """The reason a regex won't do: `//` in a value is data, not a comment."""
    got = json.loads(wbmerge.strip_jsonc('{"format": "{:%H//%M}"}'))
    assert got == {"format": "{:%H//%M}"}


def test_a_slash_star_inside_a_string_survives(wbmerge):
    got = json.loads(wbmerge.strip_jsonc('{"glob": "a/*b"}'))
    assert got == {"glob": "a/*b"}


def test_an_escaped_quote_does_not_end_the_string(wbmerge):
    got = json.loads(wbmerge.strip_jsonc(r'{"q": "a\"// still in"}'))
    assert got == {"q": 'a"// still in'}


# ── deep_merge: objects recurse, everything else replaces, null deletes ────
def test_objects_merge_key_by_key(wbmerge):
    base = {"clock": {"format": "A", "tooltip": "T"}}
    over = {"clock": {"format": "B"}}
    assert wbmerge.deep_merge(base, over) == {"clock": {"format": "B", "tooltip": "T"}}


def test_arrays_are_replaced_not_concatenated(wbmerge):
    base = {"modules-right": ["a", "b", "c"]}
    over = {"modules-right": ["c", "a"]}
    assert wbmerge.deep_merge(base, over) == {"modules-right": ["c", "a"]}


def test_null_deletes_a_key(wbmerge):
    base = {"tray": {"spacing": 8}, "clock": {}}
    over = {"tray": None}
    assert wbmerge.deep_merge(base, over) == {"clock": {}}


def test_a_new_key_is_added(wbmerge):
    assert wbmerge.deep_merge({"a": 1}, {"b": 2}) == {"a": 1, "b": 2}


def test_inputs_are_not_mutated(wbmerge):
    base = {"clock": {"format": "A"}}
    wbmerge.deep_merge(base, {"clock": {"format": "B"}})
    assert base == {"clock": {"format": "A"}}, "deep_merge must not mutate its base"


# ── End to end through the file interface ──────────────────────────────────
def test_main_merges_two_files(wbmerge, tmp_path, capsys):
    base = tmp_path / "config.jsonc"
    over = tmp_path / "waybar.jsonc"
    base.write_text('{\n  // generated\n  "modules-right": ["a", "b"],\n  "tray": {"spacing": 8}\n}\n')
    over.write_text('{\n  "modules-right": ["b"], // just b\n  "tray": null\n}\n')
    assert wbmerge.main([str(base), str(over)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {"modules-right": ["b"]}


def test_main_reports_a_broken_override(wbmerge, tmp_path, capsys):
    base = tmp_path / "config.jsonc"
    over = tmp_path / "waybar.jsonc"
    base.write_text("{}")
    over.write_text("{ not json")
    assert wbmerge.main([str(base), str(over)]) == 1
