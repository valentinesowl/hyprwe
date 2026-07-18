#!/usr/bin/env python3
"""wbmerge.py — merge a user's Waybar overrides over the generated config.

Bar COMPOSITION (which modules exist, their order, a module's on-click) is a user
choice, not a theme's — so it does not belong in theme.toml. `hwe theme apply`
renders templates/waybar/config.jsonc.j2 into a config the user must not edit
(it is regenerated every apply). This tool lets a user keep their own changes in
one small, untracked file that is deep-merged over the generated config on every
apply, so reordering a module or dropping one survives theme switches and pulls.

    wbmerge.py <base.jsonc> <override.jsonc>   # merged JSON -> stdout

Merge rules (deep_merge):
  * objects merge key-by-key, recursively;
  * everything else (arrays, strings, numbers, null) is REPLACED wholesale by the
    override. So `"modules-right": [...]` in the override fully replaces the
    generated list (the user states the order they want), while
    `"clock": {"format": "..."}` tweaks only that one key of the clock module.
  * a key set to null in the override DELETES it from the result — the one way to
    remove a generated key (e.g. drop a module's default on-click).

Both files are JSONC (Waybar's dialect: // and /* */ comments); comments are
stripped before parsing. The output is plain JSON, which Waybar also accepts.
"""
from __future__ import annotations

import json
import sys


def strip_jsonc(text: str) -> str:
    """Remove // line and /* */ block comments, but never inside a string.

    A hand-rolled scanner rather than a regex: comment markers are only comments
    OUTSIDE a JSON string, and a string may contain `//`, `/*` or an escaped
    quote. Tracking string/escape state is the only way to get that right."""
    out = []
    i, n = 0, len(text)
    in_string = False
    escaped = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        # not in a string
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
        elif ch == "/" and i + 1 < n and text[i + 1] == "/":
            i += 2
            while i < n and text[i] != "\n":
                i += 1
        elif ch == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2  # skip the closing */
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def load_jsonc(text: str):
    return json.loads(strip_jsonc(text))


def deep_merge(base, override):
    """Return base with override applied. Objects merge recursively; a null in
    the override deletes the key; anything else replaces. Neither input is
    mutated (a fresh structure is returned)."""
    if isinstance(base, dict) and isinstance(override, dict):
        result = dict(base)
        for key, value in override.items():
            if value is None:
                result.pop(key, None)
            elif key in result:
                result[key] = deep_merge(result[key], value)
            else:
                result[key] = value
        return result
    # not two objects -> the override wins wholesale
    return override


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: wbmerge.py <base.jsonc> <override.jsonc>\n")
        return 2
    base_path, override_path = argv
    try:
        with open(base_path, encoding="utf-8") as fh:
            base = load_jsonc(fh.read())
        with open(override_path, encoding="utf-8") as fh:
            override = load_jsonc(fh.read())
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"[wbmerge] {exc}\n")
        return 1
    merged = deep_merge(base, override)
    sys.stdout.write(json.dumps(merged, indent=4, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
