import '../data/datasources/sqlite_service.dart';
import 'fort_esde_library_service.dart';

/// Migrates platform provenance left by Fort's old alias-driven ES-DE model.
///
/// This service never deletes ROM rows or game metadata. It only reassigns the
/// Fort-owned source column when a concrete ES-DE identity is unambiguous, and
/// removes an obsolete overlay platform row once no ROM still depends on it.
class FortEsdePlatformReconciler {
  FortEsdePlatformReconciler._();

  static Future<int> reconcileProfile({
    required String appSystemId,
    required Map<String, String> activeSources,
  }) async {
    if (activeSources.isEmpty) return 0;
    await FortEsdeLibraryService.ensureSchema();
    final db = await SqliteService.getDatabase();

    final activeNames = <String, String>{};
    final activeRoots = <String, String>{};
    for (final entry in activeSources.entries) {
      final name = entry.key.trim();
      final root = _clean(entry.value);
      if (name.isEmpty || root == null) continue;
      final key = name.toLowerCase();
      activeNames[key] = name;
      activeRoots[key] = _trimTrailingSeparators(root);
    }
    if (activeNames.isEmpty) return 0;

    // A ROM path is usable as migration evidence only if exactly one active
    // ES-DE identity owns that root. Two explicit ES-DE systems may legally
    // share one physical directory, so a shared root must never pick a winner.
    final rootOwnerCounts = <String, int>{};
    for (final root in activeRoots.values) {
      final normalized = _normalizePath(root);
      rootOwnerCounts[normalized] = (rootOwnerCounts[normalized] ?? 0) + 1;
    }

    final canonicalRows = await db.query(
      'app_systems',
      columns: ['folder_name'],
      where: 'id = ?',
      whereArgs: [appSystemId],
      limit: 1,
    );
    final canonicalKey = canonicalRows.isEmpty
        ? null
        : canonicalRows.first['folder_name']?.toString().toLowerCase();

    final existing = await db.query(
      FortEsdeLibraryService.tableName,
      columns: ['esde_system_name', 'rom_directory'],
      where: 'app_system_id = ?',
      whereArgs: [appSystemId],
    );

    var removedPlatforms = 0;
    for (final row in existing) {
      final staleName = row['esde_system_name']?.toString().trim();
      if (staleName == null || staleName.isEmpty) continue;
      final staleKey = staleName.toLowerCase();
      if (activeNames.containsKey(staleKey)) continue;

      final staleRootRaw = _clean(row['rom_directory']?.toString());
      final staleRoot = staleRootRaw == null
          ? null
          : _trimTrailingSeparators(staleRootRaw);

      String? sameRootTarget;
      if (staleRoot != null) {
        final normalizedStaleRoot = _normalizePath(staleRoot);
        if (rootOwnerCounts[normalizedStaleRoot] == 1) {
          for (final entry in activeRoots.entries) {
            if (_normalizePath(entry.value) == normalizedStaleRoot) {
              sameRootTarget = activeNames[entry.key];
              break;
            }
          }
        }
      }

      if (sameRootTarget != null) {
        await db.update(
          'user_roms',
          {FortEsdeLibraryService.romSourceColumn: sameRootTarget},
          where:
              'app_system_id = ? AND '
              '${FortEsdeLibraryService.romSourceColumn} = ? COLLATE NOCASE',
          whereArgs: [appSystemId, staleName],
        );
      } else {
        for (final entry in activeRoots.entries) {
          final root = entry.value;
          if (rootOwnerCounts[_normalizePath(root)] != 1) continue;
          final targetName = activeNames[entry.key]!;
          await db.rawUpdate(
            '''
            UPDATE user_roms
            SET ${FortEsdeLibraryService.romSourceColumn} = ?
            WHERE app_system_id = ?
              AND ${FortEsdeLibraryService.romSourceColumn} = ? COLLATE NOCASE
              AND (
                rom_path = ?
                OR substr(rom_path, 1, length(?) + 1) = ? || '/'
                OR substr(rom_path, 1, length(?) + 1) = ? || '\\'
              )
            ''',
            [
              targetName,
              appSystemId,
              staleName,
              root,
              root,
              root,
              root,
              root,
            ],
          );
        }
      }

      var remaining = await _countRomsForSource(
        appSystemId: appSystemId,
        esdeSystemName: staleName,
      );

      // The canonical NeoStation name was the common phantom identity in the
      // previous model. If there is exactly one real ES-DE system for this
      // profile, carrying that provenance across is unambiguous and preserves
      // favourites/playtime because the user_roms row itself is untouched.
      if (remaining > 0 &&
          canonicalKey == staleKey &&
          activeNames.length == 1) {
        final targetName = activeNames.values.single;
        await db.update(
          'user_roms',
          {FortEsdeLibraryService.romSourceColumn: targetName},
          where:
              'app_system_id = ? AND '
              '${FortEsdeLibraryService.romSourceColumn} = ? COLLATE NOCASE',
          whereArgs: [appSystemId, staleName],
        );
        remaining = 0;
      }

      if (remaining == 0) {
        await db.delete(
          FortEsdeLibraryService.tableName,
          where: 'esde_system_name = ? COLLATE NOCASE',
          whereArgs: [staleName],
        );
        removedPlatforms++;
      }
    }

    return removedPlatforms;
  }

  static Future<int> _countRomsForSource({
    required String appSystemId,
    required String esdeSystemName,
  }) async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM user_roms '
      'WHERE app_system_id = ? AND '
      '${FortEsdeLibraryService.romSourceColumn} = ? COLLATE NOCASE',
      [appSystemId, esdeSystemName],
    );
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['count']?.toString() ?? '0') ?? 0;
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String _trimTrailingSeparators(String value) {
    var result = value.trim();
    while (result.length > 1 &&
        (result.endsWith('/') || result.endsWith('\\'))) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static String _normalizePath(String value) =>
      _trimTrailingSeparators(value).replaceAll('\\', '/').toLowerCase();
}
