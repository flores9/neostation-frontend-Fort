import '../data/datasources/sqlite_service.dart';
import '../models/database_game_model.dart';

/// Applies Fort's optional-by-connection strict ES-DE library semantics.
///
/// ES-DE import already records `esde_media_subdir` for every gamelist entry it
/// successfully matches, including an empty string for games in the system
/// root. That field therefore doubles as durable gamelist-membership evidence
/// without changing the database schema or hijacking the user's `is_hidden`
/// state.
///
/// Strict filtering is active only while an ES-DE folder is connected AND the
/// system has an `esde_media_dir` recorded by a successful import. Systems that
/// only have an art-only media directory but no matched gamelist rows are left
/// untouched.
class EsdeVisibilityService {
  EsdeVisibilityService._();

  static Future<List<DatabaseGameModel>> filterLibraryGames(
    List<DatabaseGameModel> games,
  ) async {
    if (games.isEmpty) return games;

    final db = await SqliteService.getDatabase();
    final configRows = await db.query(
      'user_config',
      columns: ['esde_folder_path'],
      limit: 1,
    );
    final esdeRoot = configRows.isEmpty
        ? ''
        : (configRows.first['esde_folder_path']?.toString() ?? '').trim();
    if (esdeRoot.isEmpty) return games;

    final systemIds = games
        .map((game) => game.appSystemId)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    if (systemIds.isEmpty) return games;

    final placeholders = List.filled(systemIds.length, '?').join(',');
    final args = systemIds.toList();

    // A system only enters strict mode after a successful ES-DE import has
    // recorded its media directory. Art-only systems are later excluded again
    // unless they also have gamelist membership rows below.
    final configuredRows = await db.rawQuery(
      'SELECT app_system_id FROM user_system_settings '
      'WHERE esde_media_dir IS NOT NULL AND app_system_id IN ($placeholders)',
      args,
    );
    final configuredSystems = configuredRows
        .map((row) => row['app_system_id']?.toString())
        .whereType<String>()
        .toSet();
    if (configuredSystems.isEmpty) return games;

    final allowedRows = await db.rawQuery(
      'SELECT app_system_id, filename FROM user_screenscraper_metadata '
      'WHERE esde_media_subdir IS NOT NULL AND app_system_id IN ($placeholders)',
      args,
    );

    final allowedBySystem = <String, Set<String>>{};
    for (final row in allowedRows) {
      final systemId = row['app_system_id']?.toString();
      final filename = row['filename']?.toString();
      if (systemId == null || filename == null) continue;
      allowedBySystem
          .putIfAbsent(systemId, () => <String>{})
          .add(filename.toLowerCase());
    }

    // Do not make a media-only system disappear: strictness requires at least
    // one matched gamelist row for that system.
    final strictSystems = configuredSystems
        .where(allowedBySystem.containsKey)
        .toSet();
    if (strictSystems.isEmpty) return games;

    return games.where((game) {
      final systemId = game.appSystemId;
      if (systemId == null || !strictSystems.contains(systemId)) return true;
      return allowedBySystem[systemId]!.contains(game.filename.toLowerCase());
    }).toList();
  }
}
