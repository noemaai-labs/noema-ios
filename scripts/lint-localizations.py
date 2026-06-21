#!/usr/bin/env python3
"""Validate Noema Localizable.strings files.

Checks that every supported locale parses with plutil and contains every key
present in the English localization file.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCALES_DIR = ROOT / "Noema"
BASE_LOCALE = "en.lproj"
KEY_RE = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*=')


def strings_files() -> list[Path]:
    return sorted(LOCALES_DIR.glob("*.lproj/Localizable.strings"))


def lint_with_plutil(path: Path) -> bool:
    result = subprocess.run(
        ["plutil", "-lint", str(path)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode != 0:
        print(result.stdout.strip())
        return False
    return True


def load_key_list(path: Path) -> list[str]:
    keys: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = KEY_RE.match(line)
        if match:
            keys.append(match.group(1))
    return keys


def load_keys(path: Path) -> set[str]:
    return set(load_key_list(path))


def duplicate_keys(path: Path) -> dict[str, int]:
    """Keys defined more than once. The LAST definition wins at runtime, so a later
    untranslated `"X" = "X"` silently shadows an earlier translation — this catches that."""
    counts: dict[str, int] = {}
    for key in load_key_list(path):
        counts[key] = counts.get(key, 0) + 1
    return {key: count for key, count in counts.items() if count > 1}


def main() -> int:
    files = strings_files()
    if not files:
        print("No Localizable.strings files found.", file=sys.stderr)
        return 1

    base = LOCALES_DIR / BASE_LOCALE / "Localizable.strings"
    if base not in files:
        print(f"Missing base localization: {base.relative_to(ROOT)}", file=sys.stderr)
        return 1

    failed = False
    for path in files:
        if not lint_with_plutil(path):
            failed = True

    for path in files:
        dups = duplicate_keys(path)
        if dups:
            failed = True
            print(f"{path.relative_to(ROOT)} has {len(dups)} duplicate key(s) "
                  f"(last definition wins → earlier translations are shadowed):")
            for key, count in sorted(dups.items()):
                print(f"  {key}  (x{count})")

    base_keys = load_keys(base)
    for path in files:
        keys = load_keys(path)
        missing = sorted(base_keys - keys)

        if missing:
            failed = True
            print(f"{path.relative_to(ROOT)} is missing {len(missing)} keys:")
            for key in missing:
                print(f"  {key}")

    if failed:
        return 1

    print(f"Localization lint passed for {len(files)} locale files and {len(base_keys)} base keys.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
