import '../data/datasources/sqlite_service.dart';
import '../models/database_game_model.dart';
import '../models/system_model.dart';

/// Fort-owned overlay that keeps ES-DE library identity separate from the
/// NeoStation emulation profile.
///
/// `app_system_id` remains the canonical NeoStation profile (`cpc`, `amiga`,
/// ...), while `esde_system_name` identifies the concrete library platform
/// (`amstradcpc`, `gx4000`, `amiga1200`, ...). This lets several ES-DE systems
/// inherit one upstream emulator profile without merging their ROM/media
/// namespaces.
class FortEsdeLibraryService {
  FortEsdeLibraryService._();

  static bool _schemaReady = false;

  static const String tableName = 'fort_esde_library_platforms';
  static const String romSourceColumn = 'fort_esde_system_name';

  /// Creates the Fort overlay schema idempotently.
  ///
  /// This intentionally does not mutate NeoStation's canonical system tables.
  /// The global DB migration number can adopt the same schema once the R1
  /// behaviour is device-validated; until then this guard makes development
  /// builds forward-compatible without risking an upstream table rewrite.
  static Future<void> ensureSchema() async {
    if (_schemaReady) return;
    final db = await SqliteService.getDatabase();

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName (
        esde_system_name TEXT PRIMARY KEY COLLATE NOCASE,
        app_system_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        rom_directory TEXT,
        media_directory TEXT,
        gamelist_file TEXT,
        theme TEXT,
        platform_tags TEXT,
        is_hidden INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE
      )
    ''');

    final columns = await db.rawQuery('PRAGMA table_info(user_roms)');
    final names = columns.map((row) => row['name']?.toString()).toSet();
    if (!names.contains(romSourceColumn)) {
      await db.execute(
        'ALTER TABLE user_roms ADD COLUMN $romSourceColumn TEXT COLLATE NOCASE',
      );
    }

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_fort_esde_platform_profile '
      'ON $tableName(app_system_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_user_roms_fort_esde_system '
      'ON user_roms($romSourceColumn)',
    );
    _schemaReady = true;
  }

  /// Persists one concrete ES-DE library platform while preserving its hidden
  /// state across re-imports.
  static Future<void> upsertPlatform({
    required String esdeSystemName,
    required String appSystemId,
    required String displayName,
    String? romDirectory,
    String? mediaDirectory,
    String? gamelistFile,
    String? theme,
    List<String> platformTags = const [],
  }) async {
    await ensureSchema();
    final db = await SqliteService.getDatabase();
    final key = esdeSystemName.trim();
    if (key.isEmpty) return;

    final existing = await db.query(
      tableName,
      columns: ['is_hidden'],
      where: 'esde_system_name = ? COLLATE NOCASE',
      whereArgs: [key],
      limit: 1,
    );
    final hidden = existing.isEmpty
        ? 0
        : int.tryParse(existing.first['is_hidden']?.toString() ?? '0') ?? 0;

    await db.rawInsert(
      '''
      INSERT INTO $tableName (
        esde_system_name, app_system_id, display_name, rom_directory,
        media_directory, gamelist_file, theme, platform_tags, is_hidden,
        updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
      ON CONFLICT(esde_system_name) DO UPDATE SET
        app_system_id = excluded.app_system_id,
        display_name = excluded.display_name,
        rom_directory = excluded.rom_directory,
        media_directory = excluded.media_directory,
        gamelist_file = excluded.gamelist_file,
        theme = excluded.theme,
        platform_tags = excluded.platform_tags,
        updated_at = datetime('now')
      ''',
      [
        key,
        appSystemId,
        displayName.trim().isEmpty ? key : displayName.trim(),
        _clean(romDirectory),
        _clean(mediaDirectory),
        _clean(gamelistFile),
        _clean(theme),
        platformTags.join(' '),
        hidden,
      ],
    );
  }

  /// Marks a scanned ROM as belonging to one ES-DE source platform.
  static Future<void> tagRom({
    required String romPath,
    required String esdeSystemName,
  }) async {
    await ensureSchema();
    final db = await SqliteService.getDatabase();
    await db.update(
      'user_roms',
      {romSourceColumn: esdeSystemName},
      where: 'rom_path = ?',
      whereArgs: [romPath],
    );
  }

  /// Reconstructs missing provenance from the exact ROM roots stored for ES-DE
  /// platforms. Existing provenance is never overwritten.
  ///
  /// This makes ordinary NeoStation rescans self-healing: rows inserted by the
  /// upstream scanner keep their canonical `app_system_id`, then this overlay
  /// assigns the concrete ES-DE platform from the path prefix.
  static Future<int> reconcileRomProvenance() async {
    await ensureSchema();
    final db = await SqliteService.getDatabase();
    final platforms = await db.query(
      tableName,
      columns: ['esde_system_name', 'app_system_id', 'rom_directory'],
      where: "rom_directory IS NOT NULL AND rom_directory != ''",
    );

    var updated = 0;
    for (final platform in platforms) {
      final source = platform['esde_system_name']?.toString();
      final profile = platform['app_system_id']?.toString();
      final root = platform['rom_directory']?.toString();
      if (source == null || profile == null || root == null || root.isEmpty) {
        continue;
      }
      final normalized = _trimTrailingSeparators(root);
      updated += await db.rawUpdate(
        '''
        UPDATE user_roms
        SET $romSourceColumn = ?
        WHERE app_system_id = ?
          AND ($romSourceColumn IS NULL OR $romSourceColumn = '')
          AND (
            rom_path = ?
            OR substr(rom_path, 1, length(?) + 1) = ? || '/'
            OR substr(rom_path, 1, length(?) + 1) = ? || '\\'
          )
        ''',
        [
          source,
          profile,
          normalized,
          normalized,
          normalized,
          normalized,
          normalized,
        ],
      );
    }
    return updated;
  }

  /// Returns the Fort platform row for [esdeSystemName], or null when that
  /// folder is just an ordinary NeoStation system/alias.
  static Future<Map<String, Object?>?> getPlatform(
    String esdeSystemName,
  ) async {
    await ensureSchema();
    final db = await SqliteService.getDatabase();
    final rows = await db.query(
      tableName,
      where: 'esde_system_name = ? COLLATE NOCASE',
      whereArgs: [esdeSystemName],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<bool> isLibraryPlatform(String folderName) async =>
      await getPlatform(folderName) != null;

  /// Returns the concrete ES-DE platforms that currently own at least one ROM.
  /// Each model keeps the canonical NeoStation [SystemModel.id] so emulator
  /// resolution still uses upstream data, while [SystemModel.folderName]
  /// becomes the ES-DE library identity used by the UI and media resolver.
  static Future<List<SystemModel>> getDetectedPlatformSystems() async {
    await ensureSchema();
    await reconcileRomProvenance();
    final db = await SqliteService.getDatabase();
    final platforms = await db.query(tableName);
    if (platforms.isEmpty) return const [];

    final profiles = await SqliteService.getAllSystems();
    final byId = <String, SystemModel>{
      for (final profile in profiles)
        if (profile.id != null) profile.id!: profile,
    };

    final result = <SystemModel>[];
    for (final row in platforms) {
      final source = row['esde_system_name']?.toString();
      final profileId = row['app_system_id']?.toString();
      if (source == null || profileId == null) continue;
      final profile = byId[profileId];
      if (profile == null) continue;

      final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM user_roms '
        'WHERE app_system_id = ? AND $romSourceColumn = ? COLLATE NOCASE '
        'AND is_hidden = 0',
        [profileId, source],
      );
      final count = countRows.isEmpty
          ? 0
          : int.tryParse(countRows.first['count']?.toString() ?? '0') ?? 0;
      if (count <= 0) continue;

      result.add(
        profile.copyWith(
          folderName: source,
          realName: row['display_name']?.toString() ?? source,
          romCount: count,
          detected: true,
          // The platform is a concrete source, not the canonical profile's
          // synonym set. Keeping only itself prevents future scan/media code
          // from silently collapsing sibling ES-DE platforms again.
          folders: [source],
        ),
      );
    }
    return result;
  }

  /// Canonical profile IDs represented by concrete Fort library platforms.
  /// Used to hide the old collapsed tile (`cpc`, `amiga`, ...) when its ROMs
  /// have been split into ES-DE source tiles.
  static Future<Set<String>> getRepresentedProfileIds() async {
    final systems = await getDetectedPlatformSystems();
    return systems.map((system) => system.id).whereType<String>().toSet();
  }

  /// Loads the games belonging to one concrete ES-DE platform while retaining
  /// the canonical profile ID on each [DatabaseGameModel].
  static Future<List<DatabaseGameModel>> getGamesForPlatform(
    String esdeSystemName,
  ) async {
    final platform = await getPlatform(esdeSystemName);
    if (platform == null) return const [];
    await reconcileRomProvenance();

    final profileId = platform['app_system_id']?.toString();
    if (profileId == null || profileId.isEmpty) return const [];

    final db = await SqliteService.getDatabase();
    final pathRows = await db.query(
      'user_roms',
      columns: ['rom_path'],
      where: 'app_system_id = ? AND $romSourceColumn = ? COLLATE NOCASE',
      whereArgs: [profileId, esdeSystemName],
    );
    final paths = pathRows
        .map((row) => row['rom_path']?.toString())
        .whereType<String>()
        .toSet();
    if (paths.isEmpty) return const [];

    final displayName =
        platform['display_name']?.toString() ?? esdeSystemName;
    final canonicalGames = await SqliteService.getGamesBySystem(profileId);
    return canonicalGames
        .where((game) => paths.contains(game.romPath))
        .map(
          (game) => game.copyWith(
            systemFolderName: esdeSystemName,
            systemRealName: displayName,
          ),
        )
        .toList(growable: false);
  }

  /// Resolves an otherwise ambiguous `system + filename` operation to the ROM
  /// path owned by the concrete ES-DE platform.
  static Future<String?> findRomPath(
    String esdeSystemName,
    String filename,
  ) async {
    final platform = await getPlatform(esdeSystemName);
    if (platform == null) return null;
    final profileId = platform['app_system_id']?.toString();
    if (profileId == null) return null;

    final db = await SqliteService.getDatabase();
    final rows = await db.query(
      'user_roms',
      columns: ['rom_path'],
      where:
          'app_system_id = ? AND $romSourceColumn = ? COLLATE NOCASE '
          'AND filename = ? COLLATE NOCASE',
      whereArgs: [profileId, esdeSystemName, filename],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['rom_path']?.toString();
  }

  static Future<String?> getMediaDirectory(String esdeSystemName) async {
    final row = await getPlatform(esdeSystemName);
    return _clean(row?['media_directory']?.toString());
  }

  static Future<String?> getProfileId(String esdeSystemName) async {
    final row = await getPlatform(esdeSystemName);
    return _clean(row?['app_system_id']?.toString());
  }

  static Future<Set<String>> getHiddenPlatforms() async {
    await ensureSchema();
    final db = await SqliteService.getDatabase();
    final rows = await db.query(
      tableName,
      columns: ['esde_system_name'],
      where: 'is_hidden = 1',
    );
    return rows
        .map((row) => row['esde_system_name']?.toString())
        .whereType<String>()
        .toSet();
  }

  static Future<void> setPlatformHidden(
    String esdeSystemName,
    bool hidden,
  ) async {
    await ensureSchema();
    final db = await SqliteService.getDatabase();
    await db.update(
      tableName,
      {'is_hidden': hidden ? 1 : 0},
      where: 'esde_system_name = ? COLLATE NOCASE',
      whereArgs: [esdeSystemName],
    );
  }

  /// Clears only Fort's ES-DE linkage. ROM rows and upstream metadata remain.
  static Future<void> reset() async {
    await ensureSchema();
    final db = await SqliteService.getDatabase();
    await db.update('user_roms', {
      romSourceColumn: null,
    }, where: '$romSourceColumn IS NOT NULL');
    await db.delete(tableName);
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
}
