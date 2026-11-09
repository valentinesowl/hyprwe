#!/usr/bin/env python3
"""Format `hyprctl binds -j` as HWE's read-only keybind cheatsheet."""
import json
import sys

MODIFIERS = ((1, "SHIFT"), (4, "CTRL"), (8, "ALT"), (64, "SUPER"))
KEY_NAMES = {
    "SPACE": "Space", "Escape": "Esc", "Print": "Print", "slash": "/",
    "mouse:272": "LMB", "mouse:273": "RMB",
    "mouse_down": "Wheel down", "mouse_up": "Wheel up",
}


def modifier_label(mask):
    names = [name for bit, name in MODIFIERS if int(mask) & bit]
    known = sum(bit for bit, _ in MODIFIERS if int(mask) & bit)
    if int(mask) & ~known:
        names.append(f"MOD{int(mask) & ~known}")
    return names


def rows(bindings):
    seen = set()
    for bind in bindings:
        key = bind.get("key", "")
        description = bind.get("description") or bind.get("dispatcher") or "Lua action"
        if key.startswith("XF86"):
            continue
        summary = None
        if description.startswith("Switch to workspace"):
            summary = ("workspace-switch", "SUPER + 1…0", "Switch to workspace")
        elif description.startswith("Move window to workspace"):
            summary = ("workspace-move", "SUPER + SHIFT + 1…0", "Move window to workspace")
        elif description.startswith("Move focus "):
            summary = ("focus-arrows", "SUPER + ← ↑ ↓ →", "Move focus")
        elif description.startswith("Move window ") and not description.startswith("Move window to "):
            summary = ("window-arrows", "SUPER + SHIFT + ← ↑ ↓ →", "Move window")
        if summary:
            if summary[0] in seen:
                continue
            seen.add(summary[0])
            yield summary[1], summary[2]
            continue
        pretty = KEY_NAMES.get(key, key)
        mods = modifier_label(bind.get("modmask", 0))
        label = " + ".join([*mods, pretty]) if mods else pretty
        yield label, description


def render(bindings):
    return "".join(f"  {label:<22}  {description}\n" for label, description in rows(bindings))


def main():
    try:
        bindings = json.load(sys.stdin)
        if not isinstance(bindings, list):
            raise ValueError("expected a JSON array")
        sys.stdout.write(render(bindings))
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        sys.exit(f"keybinds: invalid hyprctl JSON: {exc}")


if __name__ == "__main__":
    main()
