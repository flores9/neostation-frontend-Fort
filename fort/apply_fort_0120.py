#!/usr/bin/env python3
"""Apply NeoStation Fort vNext additions on top of the 0.12.0+128 baseline.

This overlay intentionally keeps the ES-DE multi-root work from the previous
Fort line while retiring the discarded global MAME rompath repair. It also
adds Fort-only release/update policy and a narrow MAME4droid auto-selection
guard without changing upstream behavior for other standalone emulators.
"""
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


def patch_mame4droid_auto_priority() -> None:
    path = "lib/services/game/game_launch_service.dart"
    replace_once(
        path,
        """    for (final e in all) {
      if (e.isInstalled && e.isStandalone) return e;
    }

    // 3. Fall back through installed configured default → any installed → raw.""",
        """    for (final e in all) {
      if (!e.isInstalled || !e.isStandalone) continue;

      // Fort adds MAME4droid profiles to systems whose upstream configured
      // default is often a RetroArch core. Merely installing MAME4droid must
      // not silently replace that configured core. An explicit user default
      // still wins above, so manual MAME selection remains fully supported.
      final packageName = e.androidPackageName?.toLowerCase();
      final isFortMame4droid =
          packageName == 'com.seleuco.mame4d2024' ||
          packageName == 'com.seleuco.mame4droid';
      if (isFortMame4droid &&
          configured != null &&
          !configured.isStandalone &&
          configured.uniqueId != e.uniqueId) {
        _log.i(
          '[EmuSel] Fort: keeping configured core ${configured.uniqueId} '
          'ahead of installed MAME4droid ${e.uniqueId}',
        );
        continue;
      }

      return e;
    }

    // 3. Fall back through installed configured default → any installed → raw.""",
    )


def patch_official_app_updates() -> None:
    path = "lib/services/update_service.dart"
    replace_once(
        path,
        "class UpdateService {\n",
        """class UpdateService {
  static const bool _fortPreviewBuild =
      bool.fromEnvironment('FORT_PREVIEW', defaultValue: false);
""",
    )
    replace_once(
        path,
        "    if (kIsWeb) return null;\n",
        """    // A Fort Preview is a separate product/package. Never present an
    // upstream NeoStation APK as an in-place update for the fork.
    if (kIsWeb || _fortPreviewBuild) return null;
""",
    )


def patch_official_system_updates() -> None:
    path = "lib/services/systems_update_service.dart"
    replace_once(
        path,
        """const _githubApiUrl =
    'https://api.github.com/repos/misobadev/neostation-frontend/contents/assets/systems';

final _log = LoggerService.instance;""",
        """const _githubApiUrl =
    'https://api.github.com/repos/misobadev/neostation-frontend/contents/assets/systems';

const bool _fortPreviewBuild =
    bool.fromEnvironment('FORT_PREVIEW', defaultValue: false);

final _log = LoggerService.instance;""",
    )
    replace_once(
        path,
        """  static Future<String?> getCachedSystemPath(String jsonFileName) async {
    try {""",
        """  static Future<String?> getCachedSystemPath(String jsonFileName) async {
    // Fort system definitions are authoritative. A cache previously downloaded
    // by official NeoStation must never shadow the JSON bundled in this APK.
    if (_fortPreviewBuild) return null;
    try {""",
    )
    replace_once(
        path,
        """    // Step 1: always check bundled vs cached — independent of app version tracking.
    await _syncBundledVersion();

    // Step 2: track app version changes (best-effort).""",
        """    // Step 1: Fort always resets to its bundled system generation and
    // removes any official cache left by a previous install/data migration.
    if (_fortPreviewBuild) {
      await _clearSystemsCache();
      final bundledVersion = await _readBundledManifestVersion();
      if (bundledVersion.isNotEmpty) {
        await SqliteService.updateSystemsVersion(bundledVersion);
        _log.i(
          'SystemsUpdateService: Fort authoritative systems v$bundledVersion',
        );
      }
    } else {
      await _syncBundledVersion();
    }

    // Step 2: track app version changes (best-effort).""",
    )
    replace_once(
        path,
        """  static Future<bool> cacheIsNewerThanBundle() async {
    try {""",
        """  static Future<bool> cacheIsNewerThanBundle() async {
    if (_fortPreviewBuild) return false;
    try {""",
    )
    replace_once(
        path,
        """  static Future<SystemsUpdateInfo?> checkForUpdate() async {
    try {""",
        """  static Future<SystemsUpdateInfo?> checkForUpdate() async {
    // The official systems manifest is not an update channel for Fort.
    if (_fortPreviewBuild) return null;
    try {""",
    )
    replace_once(
        path,
        """  static Future<SystemsUpdateResult?> checkAndUpdate({
    SystemsUpdateInfo? knownUpdate,
    void Function(double progress, String status)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    try {""",
        """  static Future<SystemsUpdateResult?> checkAndUpdate({
    SystemsUpdateInfo? knownUpdate,
    void Function(double progress, String status)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (_fortPreviewBuild) return null;
    try {""",
    )


def main() -> int:
    base.main()
    patch_settings_import()
    patch_setup_import()
    patch_mame4droid_auto_priority()
    patch_official_app_updates()
    patch_official_system_updates()
    print("Fort 0.12.0 vNext overlay applied successfully (no MAME rompath repair).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
