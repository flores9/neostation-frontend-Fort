import '../data/datasources/sqlite_service.dart';
import '../models/database_game_model.dart';

/// Applies Fort's strict ES-DE library semantics.
///
/// Gamelist membership is intentionally stored independently from metadata and
/// from `user_roms`. ES-DE can be imported before NeoStation has scanned every
/// ROM root; in that case the upstream importer correctly reports the missing
/// ROM as unmatched and skips its metadata, but the gamelist still tells us
/// whether that future ROM should be visible. Persisting that membership here
/// makes strict mode independent of scan/import order.
class EsdeVisibilityService {
  EsdeVisibilityService._();

  static const String _systemsTable = 'user_esde_gamelist_systems';
  static const String _entriesTable = 'user_esde_gamelist_entries';
  static const String _lcdGamesSystemId = 'lcdgames';

  static Future<void> _ensureSchema(DatabaseExecutorAdapter db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_systemsTable (
        app_system_id TEXT PRIMARY KEY,
        imported_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_entriesTable (
        app_system_id TEXT NOT NULL,
        filename_key TEXT NOT NULL,
        PRIMARY KEY (app_system_id, filename_key)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_esde_gamelist_entries_system '
      'ON $_entriesTable(app_system_id)',
    );
  }

  /// Starts a new ES-DE import snapshot.
  ///
  /// Membership is rebuilt from the XML files on every import so removed
  /// gamelist entries cannot survive as stale visibility allowances.
  static Future<void> prepareImport() async {
    final db = await SqliteService.getDatabase();
    await _ensureSchema(db);
    await db.delete(_entriesTable);
    await db.delete(_systemsTable);
  }

  /// Records one successfully parsed ES-DE system and all filenames exposed by
  /// its gamelist, even when NeoStation has not scanned those files yet.
  ///
  /// Filenames are normalized case-insensitively because ES-DE matching and the
  /// importer already treat ROM basenames that way.
  static Future<void> recordSystemMembership(
    String appSystemId,
    Iterable<String> filenames,
  ) async {
    final db = await SqliteService.getDatabase();
    await _ensureSchema(db);

    await db.insert(
      _systemsTable,
      {'app_system_id': appSystemId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final normalized = filenames
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();

    final batch = db.batch();
    for (final filename in normalized) {
      batch.insert(
        _entriesTable,
        {'app_system_id': appSystemId, 'filename_key': filename},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Clears only Fort's ES-DE visibility snapshot. ROMs and user hidden-state
  /// are deliberately untouched.
  static Future<void> clearMembership() async {
    final db = await SqliteService.getDatabase();
    await _ensureSchema(db);
    await db.delete(_entriesTable);
    await db.delete(_systemsTable);
  }

  /// Removes the stale LCD duplicate shape seen on upgraded Fort databases.
  ///
  /// The duplicate rows share the same `lcdgames` system and ROM filename but
  /// carry different `rom_path` spellings. The first row is the launchable one
  /// on-device; the stale second row fails at emulator handoff. This is
  /// deliberately *not* a title-based distinct: two different ROM filenames
  /// may legitimately resolve to the same display title, and every other
  /// system remains untouched.
  static List<DatabaseGameModel> _dedupeLcdGames(
    List<DatabaseGameModel> games,
  ) {
    final seen = <String>{};
    return games.where((game) {
      if (game.appSystemId?.toLowerCase() != _lcdGamesSystemId) return true;

      final filenameKey = game.filename.trim().toLowerCase();
      if (filenameKey.isEmpty) return true;
      return seen.add(filenameKey);
    }).toList();
  }

  static Future<List<DatabaseGameModel>> filterLibraryGames(
    List<DatabaseGameModel> games,
  ) async {
    if (games.isEmpty) return games;

    // Do this before the ES-DE guards so an upgraded database is repaired at
    // presentation time even before the user runs another ES-DE import.
    final candidateGames = _dedupeLcdGames(games);

    final db = await SqliteService.getDatabase();
    final configRows = await db.query(
      'user_config',
      columns: ['esde_folder_path'],
      limit: 1,
    );
    final esdeRoot = configRows.isEmpty
        ? ''
        : (configRows.first['esde_folder_path']?.toString() ?? '').trim();
    if (esdeRoot.isEmpty) return candidateGames;

    final systemIds = candidateGames
        .map((game) => game.appSystemId)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    if (systemIds.isEmpty) return candidateGames;

    await _ensureSchema(db);

    final placeholders = List.filled(systemIds.length, '?').join(',');
    final args = systemIds.toList();

    final strictRows = await db.rawQuery(
      'SELECT app_system_id FROM $_systemsTable '
      'WHERE app_system_id IN ($placeholders)',
      args,
    );
    final strictSystems = strictRows
        .map((row) => row['app_system_id']?.toString())
        .whereType<String>()
        .toSet();
    if (strictSystems.isEmpty) return candidateGames;

    final allowedRows = await db.rawQuery(
      'SELECT app_system_id, filename_key FROM $_entriesTable '
      'WHERE app_system_id IN ($placeholders)',
      args,
    );
    final allowedBySystem = <String, Set<String>>{};
    for (final row in allowedRows) {
      final systemId = row['app_system_id']?.toString();
      final filename = row['filename_key']?.toString();
      if (systemId == null || filename == null) continue;
      allowedBySystem.putIfAbsent(systemId, () => <String>{}).add(filename);
    }

    return candidateGames.where((game) {
      final systemId = game.appSystemId;
      if (systemId == null || !strictSystems.contains(systemId)) return true;
      final allowed = allowedBySystem[systemId] ?? const <String>{};
      return allowed.contains(game.filename.toLowerCase());
    }).toList();
  }
}
