#!/usr/bin/env python3
"""Fails when the i18n files and the @i18n(key)@ tags in src/ disagree.

  * every i18n/<lang>.json has exactly the keys of i18n/en.json
  * every @i18n(key)@ used in src/**/*.lua exists in en.json
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TAG_RE = re.compile(r"@i18n\(([\w.]+)\)")


def flat_keys(data: dict, prefix: str = "") -> set[str]:
    keys: set[str] = set()
    for key, value in data.items():
        if isinstance(value, dict):
            keys |= flat_keys(value, f"{prefix}{key}.")
        else:
            keys.add(prefix + key)
    return keys


def load(path: Path) -> set[str]:
    return flat_keys(json.loads(path.read_text(encoding="utf-8")))


def main() -> int:
    i18n = REPO / "i18n"
    en = load(i18n / "en.json")
    problems: list[str] = []

    for path in sorted(i18n.glob("*.json")):
        keys = load(path)
        problems += [f"{path.name}: missing {k}" for k in sorted(en - keys)]
        problems += [f"{path.name}: extra {k}" for k in sorted(keys - en)]

    used: set[str] = set()
    for lua in sorted((REPO / "src").rglob("*.lua")):
        used |= set(TAG_RE.findall(lua.read_text(encoding="utf-8")))
    problems += [f"src uses @i18n({k})@ but en.json has no such key" for k in sorted(used - en)]

    for line in problems:
        print(line)
    if not problems:
        print(f"[i18n] OK: {len(en)} keys, {len(used)} used in src/")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
