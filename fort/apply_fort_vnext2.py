#!/usr/bin/env python3
"""Apply Fort vNext.2 additions after the vNext overlay."""
from __future__ import annotations

import pathlib
import sys

import apply_fort_vnext as base

ROOT = pathlib.Path(__file__).resolve().parents[1]


def replace_once(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"{path}: expected exactly 1 anchor, found {count}: {old[:120]!r}"
        )
    target.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"patched {path}")


def patch_mame4droid_rompath() -> None:
    path = "lib/services/launcher_service.dart"
    replace_once(
        path,
        """            final resolvedValue = resolvePlaceholdersAndroid(
              rawValue,
              game,
              system,
            );

            extra['value'] = resolvedValue;""",
        """            var resolvedValue = resolvePlaceholdersAndroid(
              rawValue,
              game,
              system,
            );
            if (extra['key'] == 'cli_params' && game.romPath != null) {
              resolvedValue = FortAndroidRomPath.ensureMameRomRoot(
                resolvedValue,
                game.romPath!,
                system,
              );
            }

            extra['value'] = resolvedValue;""",
    )


def patch_settings_import() -> None:
    path = "lib/screens/settings_screen/new_settings_options/directories_settings_content.dart"
    replace_once(
        path,
        "import 'package:neostation/services/esde_import_service.dart';\n",
        "import 'package:neostation/services/esde_import_service.dart';\n"
        "import 'package:neostation/services/esde_rom_roots_service.dart';\n",
    )
    replace_once(
        path,
        """    try {
      result = await EsdeImportService.import(
        root,""",
        """    try {
      await EsdeRomRootsService.syncAndScan(
        context.read<SqliteConfigProvider>(),
        root,
      );
      if (mounted) await _loadCurrentPaths();

      result = await EsdeImportService.import(
        root,""",
    )


def patch_setup_import() -> None:
    path = "lib/widgets/setup_wizard.dart"
    replace_once(
        path,
        "import 'package:neostation/services/esde_import_service.dart';\n",
        "import 'package:neostation/services/esde_import_service.dart';\n"
        "import 'package:neostation/services/esde_rom_roots_service.dart';\n",
    )
    replace_once(
        path,
        """    await context.read<SqliteConfigProvider>().updateEsdeFolderPath(selected);

    setState(() {""",
        """    final configProvider = context.read<SqliteConfigProvider>();
    await configProvider.updateEsdeFolderPath(selected);

    setState(() {""",
    )
    replace_once(
        path,
        """    try {
      result = await EsdeImportService.import(
        selected,""",
        """    try {
      await EsdeRomRootsService.syncAndScan(
        configProvider,
        selected,
      );

      result = await EsdeImportService.import(
        selected,""",
    )


def main() -> int:
    base.main()
    patch_mame4droid_rompath()
    patch_settings_import()
    patch_setup_import()
    print("Fort vNext.2 overlay applied successfully.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
