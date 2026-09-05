#!/usr/bin/env python3
"""Normalize and audit the decoded Fort systems payload before packaging."""
from __future__ import annotations

import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SYSTEMS = ROOT / "assets" / "systems"
PRESERVED_UPSTREAM = ROOT / "build" / "fort" / "upstream_systems"
OLD_MAME_LABEL = "MAME4droid 2024"
NEW_MAME_LABEL = "MAME4droid Current"


def restore_preserved_upstream_systems() -> list[str]:
    """Restore upstream-only virtual systems after the Fort payload swap."""
    restored = []
    if not PRESERVED_UPSTREAM.is_dir():
        return restored

    for source in sorted(PRESERVED_UPSTREAM.glob("*.json")):
        target = SYSTEMS / source.name
        shutil.copy2(source, target)
        restored.append(source.name)
    return restored


def replace_label(value):
    if isinstance(value, dict):
        return {key: replace_label(item) for key, item in value.items()}
    if isinstance(value, list):
        return [replace_label(item) for item in value]
    if isinstance(value, str):
        return value.replace(OLD_MAME_LABEL, NEW_MAME_LABEL)
    return value


def dedupe_casefold(values):
    seen = set()
    result = []
    for value in values:
        key = str(value).casefold()
        if key in seen:
            continue
        seen.add(key)
        result.append(value)
    return result


def is_lcd_candidate(path: pathlib.Path, data: dict) -> bool:
    system = data.get("system") or {}
    tokens = [
        path.stem,
        str(system.get("id", "")),
        str(system.get("name", "")),
        str(system.get("short_name", "")),
        *(str(value) for value in system.get("folders", []) or []),
    ]
    text = " ".join(tokens).casefold()
    return any(token in text for token in ("lcd", "gameandwatch", "game & watch"))


def main() -> int:
    restored = restore_preserved_upstream_systems()
    files = sorted(SYSTEMS.glob("*.json"))
    if not files:
        raise RuntimeError("Fort systems payload is empty")
    if "collections.json" not in {file.name for file in files}:
        raise RuntimeError("NeoStation 0.12 collections.json was not preserved")

    renamed_files = []
    deduped_folders = []
    lcd = []
    alias_owners = {}

    for file in files:
        original = json.loads(file.read_text(encoding="utf-8"))
        data = replace_label(original)
        system = data.get("system") or {}

        folders = system.get("folders")
        if isinstance(folders, list):
            normalized = dedupe_casefold(folders)
            if normalized != folders:
                system["folders"] = normalized
                deduped_folders.append(file.name)
            for folder in normalized:
                alias_owners.setdefault(str(folder).casefold(), []).append(
                    (str(system.get("id", file.stem)), file.name)
                )

        if data != original:
            if OLD_MAME_LABEL in json.dumps(original, ensure_ascii=False):
                renamed_files.append(file.name)
            file.write_text(
                json.dumps(data, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

        if is_lcd_candidate(file, data):
            lcd.append(
                {
                    "file": file.name,
                    "id": system.get("id"),
                    "name": system.get("name"),
                    "folders": system.get("folders", []),
                    "extensions": system.get("extensions", []),
                    "emulators": [
                        {
                            "name": emulator.get("name"),
                            "unique_id": emulator.get("unique_id"),
                        }
                        for emulator in data.get("emulators", [])
                    ],
                }
            )

    stale = []
    for file in files:
        if OLD_MAME_LABEL in file.read_text(encoding="utf-8"):
            stale.append(file.name)
    if stale:
        raise RuntimeError(f"stale MAME4droid 2024 labels remain: {stale}")

    shared_lcd_aliases = {}
    lcd_ids = {str(item.get("id", "")).casefold() for item in lcd}
    for alias, owners in alias_owners.items():
        owner_ids = {owner[0].casefold() for owner in owners}
        if len(owner_ids) > 1 and (owner_ids & lcd_ids):
            shared_lcd_aliases[alias] = owners

    print(f"Restored upstream-only systems: {restored}")
    print(f"Fort systems normalized: {len(files)} JSON files")
    print(f"MAME4droid display label updated in: {renamed_files}")
    print(f"Duplicate folder aliases removed within files: {deduped_folders}")
    print("FORT_LCD_AUDIT=" + json.dumps(lcd, ensure_ascii=False, sort_keys=True))
    print(
        "FORT_LCD_SHARED_ALIASES="
        + json.dumps(shared_lcd_aliases, ensure_ascii=False, sort_keys=True)
    )

    if not lcd:
        print("WARNING: no LCD Games candidate found in Fort payload", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
