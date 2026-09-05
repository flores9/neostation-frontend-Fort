#!/usr/bin/env python3
"""Apply NeoStation Fort vNext as a small, rebasing-friendly overlay.

Authoritative upstream baseline when authored:
  de7de7d5584c815769817cc74f1745d28800d7be (2026-09-05)

The patch intentionally uses exact textual anchors and fails closed if upstream
changes those anchors. That makes future rebases explicit instead of silently
applying a stale transformation to different code.
"""
from __future__ import annotations

import pathlib
import sys

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


def replace_all_expected(path: str, old: str, new: str, expected: int) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    count = text.count(old)
    if count != expected:
        raise RuntimeError(
            f"{path}: expected {expected} anchors, found {count}: {old[:120]!r}"
        )
    target.write_text(text.replace(old, new), encoding="utf-8")
    print(f"patched {path} ({expected} replacements)")


def patch_launcher() -> None:
    path = "lib/services/launcher_service.dart"
    replace_once(
        path,
        "import 'systems_update_service.dart';\n",
        "import 'systems_update_service.dart';\n"
        "import '../utils/fort_android_rom_path.dart';\n",
    )

    # Pass SystemModel into Android placeholder resolution so {rom.root} can be
    # derived from the actual system aliases rather than hardcoded storage paths.
    replace_all_expected(
        path,
        "resolvePlaceholdersAndroid(result['data'], game)",
        "resolvePlaceholdersAndroid(result['data'], game, system)",
        1,
    )
    replace_all_expected(
        path,
        "resolvePlaceholdersAndroid(rawValue, game)",
        "resolvePlaceholdersAndroid(rawValue, game, system)",
        1,
    )
    replace_once(
        path,
        """resolvePlaceholdersAndroid(
            platformConfig['data'],
            game,
          )""",
        """resolvePlaceholdersAndroid(
            platformConfig['data'],
            game,
            system,
          )""",
    )
    replace_all_expected(
        path,
        "resolvePlaceholdersAndroid(val, game)",
        "resolvePlaceholdersAndroid(val, game, system)",
        1,
    )

    replace_once(
        path,
        "String resolvePlaceholdersAndroid(String template, GameModel game) {",
        """String resolvePlaceholdersAndroid(
    String template,
    GameModel game,
    SystemModel system,
  ) {""",
    )

    replace_once(
        path,
        """      final String romPath = game.romPath!;

      // {file.path} and {file.localuri} use marker-based resolution: Kotlin's""",
        """      final String romPath = game.romPath!;

      // Fort ES-DE/MAME placeholders are resolved here, before Android Intent
      // tokenization. MAME4droid receives cli_params as one string extra, so a
      // neostation-realpath marker embedded in that larger string cannot be
      // resolved later by Kotlin's prefix-based marker resolver.
      result = result.replaceAll(
        '{file.rawpath}',
        FortAndroidRomPath.rawPath(romPath),
      );
      result = result.replaceAll(
        '{file.dir}',
        FortAndroidRomPath.fileDirectory(romPath),
      );
      result = result.replaceAll(
        '{rom.root}',
        FortAndroidRomPath.romRoot(romPath, system),
      );
      result = result.replaceAll(
        '{file.basename}',
        FortAndroidRomPath.basenameWithoutExtension(game.romname),
      );

      // {file.path} and {file.localuri} use marker-based resolution: Kotlin's""",
    )


def patch_esde_visibility() -> None:
    path = "lib/services/game/game_list_service.dart"
    replace_once(
        path,
        "import '../../constants/system_folder_names.dart';\n",
        "import '../../constants/system_folder_names.dart';\n"
        "import '../esde_visibility_service.dart';\n",
    )

    replace_once(
        path,
        """        final databaseGames = (await GameRepository.getAllGames())
            .where(""",
        """        final visibleGames = await EsdeVisibilityService.filterLibraryGames(
          await GameRepository.getAllGames(),
        );
        final databaseGames = visibleGames
            .where(""",
    )

    replace_once(
        path,
        """      final databaseGames = (await GameRepository.getGamesBySystem(
        system.id!,
      )).where((dbGame) => !dbGame.isHidden).toList();""",
        """      final visibleGames = await EsdeVisibilityService.filterLibraryGames(
        await GameRepository.getGamesBySystem(system.id!),
      );
      final databaseGames = visibleGames
          .where((dbGame) => !dbGame.isHidden)
          .toList();""",
    )

    replace_once(
        path,
        """    final databaseGames = (await GameRepository.getFavoriteGames())
        .where((dbGame) => !dbGame.isHidden)
        .toList();""",
        """    final visibleGames = await EsdeVisibilityService.filterLibraryGames(
      await GameRepository.getFavoriteGames(),
    );
    final databaseGames = visibleGames
        .where((dbGame) => !dbGame.isHidden)
        .toList();""",
    )

    replace_once(
        path,
        """      final databaseGames = (await CollectionRepository.getGamesInCollection(
        collectionId,
      )).where((dbGame) => !dbGame.isHidden).toList();""",
        """      final visibleGames = await EsdeVisibilityService.filterLibraryGames(
        await CollectionRepository.getGamesInCollection(collectionId),
      );
      final databaseGames = visibleGames
          .where((dbGame) => !dbGame.isHidden)
          .toList();""",
    )

    search = "lib/screens/search_screen/search_screen.dart"
    replace_once(
        search,
        "import 'package:neostation/services/game_service.dart';\n",
        "import 'package:neostation/services/game_service.dart';\n"
        "import 'package:neostation/services/esde_visibility_service.dart';\n",
    )
    replace_once(
        search,
        """    final games = (await GameRepository.getAllGames())
        .where((g) => !g.isHidden)
        .toList();""",
        """    final visibleGames = await EsdeVisibilityService.filterLibraryGames(
      await GameRepository.getAllGames(),
    );
    final games = visibleGames.where((g) => !g.isHidden).toList();""",
    )


def main() -> int:
    patch_launcher()
    patch_esde_visibility()
    print("Fort vNext code overlay applied successfully.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
