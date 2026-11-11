#!/usr/bin/env python3
"""Print CAPS LOCK when the compositor reports it active; otherwise print nothing."""
import json
import subprocess
import sys


def caps_lock_active(devices: dict) -> bool:
    return any(keyboard.get("capsLock") for keyboard in devices.get("keyboards", []))


def main() -> int:
    try:
        result = subprocess.run(
            ["hyprctl", "devices", "-j"], capture_output=True, text=True, check=True, timeout=1
        )
        active = caps_lock_active(json.loads(result.stdout))
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return 0
    if active:
        print("CAPS LOCK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
