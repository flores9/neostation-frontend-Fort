import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../data/datasources/sqlite_service.dart';
import '../repositories/scraper_repository.dart';
import 'esde_config_resolver.dart';
import 'logger_service.dart';

/// Summary of an ES-DE import run, surfaced to the settings UI.
class EsdeImportResult {
  /// Number of ES-DE system folders matched to a NeoStation system.
  final int systemsMatched;

  /// Number of ES-DE system folders that could not be mapped and were skipped.
  final int systemsUnmatched;

  /// Number of ES-DE system folders that mapped to a NeoStation system but
  /// whose `gamelist.xml` could not be read or parsed (skipped).
  final int systemsSkipped;

  /// Number of `<game>` entries whose metadata was created or filled.
  final int gamesImported;

  /// Number of `<game>` entries with no matching scanned ROM (skipped).
  final int gamesUnmatched;

  /// Number of games whose favorite / play-stat fields were updated.
  final int statsUpdated;

  /// Whether at least one usable ES-DE gamelist source was found. Historically
  /// this meant a central `gamelists/` directory existed; Fort broadens the
  /// meaning so ROM-local gamelists are valid ES-DE sources too.
  final bool gamelistsDirFound;

  const EsdeImportResult({
    this.systemsMatched = 0,
    this.systemsUnmatched = 0,
    this.systemsSkipped = 0,
    this.gamesImported = 0,
    this.gamesUnmatched = 0,
    this.statsUpdated = 0,
    this.gamelistsDirFound = true,
  });

  EsdeImportResult _add({
    int systemsMatched = 0,
    int systemsUnmatched = 0,
    int systemsSkipped = 0,
    int gamesImported = 0,
    int gamesUnmatched = 0,
    int statsUpdated = 0,
  }) {
    return EsdeImportResult(
      systemsMatched: this.systemsMatched + systemsMatched,
      systemsUnmatched: this.systemsUnmatched + systemsUnmatched,
      systemsSkipped: this.systemsSkipped + systemsSkipped,
      gamesImported: this.gamesImported + gamesImported,
      gamesUnmatched: this.gamesUnmatched + gamesUnmatched,
      statsUpdated: this.statsUpdated + statsUpdated,
      gamelistsDirFound: gamelistsDirFound,
    );
  }
}

class _EsdeGamelistSource {
  final String esdeSystemName;
  final File file;
  final String mediaDirectory;

  const _EsdeGamelistSource({
    required this.esdeSystemName,
    required this.file,
    required this.mediaDirectory,
  });
}

/// Imports metadata and wires up fallback artwork from an ES-DE
/// (EmulationStation Desktop Edition) installation.
///
/// Fort resolves ES-DE's actual configuration instead of assuming all data is
/// under `<ES-DE>/gamelists` and `<ES-DE>/downloaded_media`. The importer reads
/// `settings/es_settings.xml` plus `custom_systems/es_systems.xml`, supports
/// ROM-local gamelists and custom per-system ROM paths, and honours an external
/// `MediaDirectory`. ES-DE files remain read-only; later NeoStation scrapes are
/// still written to NeoStation's own media directory.
class EsdeImportService {
  static final _log = LoggerService.instance;

  /// Runs the import against [esdeRoot] (the ES-DE application folder).
  ///
  /// [onProgress] is invoked as `(fraction 0..1, currentSystemLabel)`.
  static Future<EsdeImportResult> import(
    String esdeRoot, {
    void Function(double progress, String label)? onProgress,
  }) async {
    var result = const EsdeImportResult();
    _mediaIndexCache.clear();

    final resolved = await EsdeConfigResolver.load(esdeRoot);
    final sources = await _discoverGamelists(resolved);
    if (sources.isEmpty) {
      _log.w(
        'ES-DE import: no central or ROM-local gamelist.xml found at $esdeRoot',
      );
      return const EsdeImportResult(gamelistsDirFound: false);
    }

    final importedDirs = <String>{};
    final preferredLang = await ScraperRepository.getPreferredLanguage();
    final descColumn = _descriptionColumn(preferredLang);

    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      final esdeDirName = source.esdeSystemName;
      onProgress?.call(i / sources.length, esdeDirName);

      final system = await ScraperRepository.resolveSystemByFolderName(
        esdeDirName,
      );
      if (system == null) {
        _log.i(
          'ES-DE import: no NeoStation system for "$esdeDirName", skipping',
        );
        result = result._add(systemsUnmatched: 1);
        continue;
      }

      final appSystemId = system['app_system_id']!;
      final matchedBefore = result.systemsMatched;
      result = await _importSystem(
        esdeDirName: esdeDirName,
        appSystemId: appSystemId,
        gamelistFile: source.file,
        mediaDirectory: source.mediaDirectory,
        descColumn: descColumn,
        accumulator: result,
        onGameProgress: onProgress == null
            ? null
            : (fraction) =>
                  onProgress((i + fraction) / sources.length, esdeDirName),
      );

      if (result.systemsMatched > matchedBefore) {
        await _recordEsdeMediaDir(
          esdeDirName,
          appSystemId,
          mediaDirectory: source.mediaDirectory,
        );
        importedDirs.add(esdeDirName.toLowerCase());
      }
    }

    await _linkMediaOnlySystems(resolved, importedDirs);

    onProgress?.call(1.0, '');
    _log.i(
      'ES-DE import done: systems matched=${result.systemsMatched} '
      'unmatched=${result.systemsUnmatched} skipped=${result.systemsSkipped}, '
      'games imported=${result.gamesImported} noRomMatch=${result.gamesUnmatched}, '
      'stats updated=${result.statsUpdated}',
    );
    return result;
  }

  /// Discovers gamelists from every ES-DE location Fort understands.
  ///
  /// Candidate system names come from the modern central gamelist tree, ES-DE
  /// custom-system paths, and NeoStation's known primary/alias folder names.
  /// The last source is what lets a global `ROMDirectory` expose legacy
  /// `<ROMDirectory>/<system>/gamelist.xml` files even when no central gamelist
  /// exists. Each system then uses [EsdeResolvedConfig.forSystem]'s priority.
  static Future<List<_EsdeGamelistSource>> _discoverGamelists(
    EsdeResolvedConfig resolved,
  ) async {
    final names = <String>{};
    final central = Directory(path.join(resolved.esdeRoot, 'gamelists'));
    if (central.existsSync()) {
      for (final dir in central.listSync().whereType<Directory>()) {
        if (File(path.join(dir.path, 'gamelist.xml')).existsSync()) {
          names.add(path.basename(dir.path));
        }
      }
    }

    names.addAll(resolved.customSystemRomPaths.keys);

    // Include all primary and alias folder names so a ROM-local gamelist can be
    // discovered under the global ROMDirectory without guessing system names.
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery('''
        SELECT folder_name FROM app_systems
        UNION
        SELECT folder_name FROM app_system_folders
      ''');
      for (final row in rows) {
        final name = row['folder_name']?.toString().trim();
        if (name != null && name.isNotEmpty) names.add(name);
      }
    } catch (e) {
      _log.w('ES-DE import: could not enumerate system aliases: $e');
    }

    final deduped = <String, _EsdeGamelistSource>{};
    for (final name in names) {
      final paths = resolved.forSystem(name);
      final gamelist = paths.firstExistingGamelist;
      if (gamelist == null) continue;
      final canonical = path.normalize(gamelist).toLowerCase();
      deduped.putIfAbsent(
        canonical,
        () => _EsdeGamelistSource(
          esdeSystemName: name,
          file: File(gamelist),
          mediaDirectory: paths.mediaDirectory,
        ),
      );
    }

    final sources = deduped.values.toList()
      ..sort((a, b) => a.esdeSystemName.compareTo(b.esdeSystemName));
    return sources;
  }

  /// Clears all ES-DE-imported data so the import can be re-run from scratch.
  /// Deletes only metadata rows the ES-DE import itself created
  /// (`esde_imported = 1`) that a later NeoStation scrape hasn't upgraded
  /// (`is_fully_scraped = 0`) — never NeoStation's own partially-scraped rows.
  static Future<int> reset() async {
    final db = await SqliteService.getDatabase();
    final deleted = await db.delete(
      'user_screenscraper_metadata',
      where: 'esde_imported = 1 AND is_fully_scraped = 0',
    );
    await db.update('user_system_settings', {
      'esde_media_dir': null,
    }, where: 'esde_media_dir IS NOT NULL');
    _log.i('ES-DE reset: cleared $deleted metadata rows and media dirs');
    return deleted;
  }

  /// Links artwork for systems that have media but no gamelist.
  static Future<void> _linkMediaOnlySystems(
    EsdeResolvedConfig resolved,
    Set<String> importedDirs,
  ) async {
    final mediaRoot = Directory(resolved.mediaRoot);
    if (!mediaRoot.existsSync()) return;

    for (final dir in mediaRoot.listSync().whereType<Directory>()) {
      final esdeDirName = path.basename(dir.path);
      if (importedDirs.contains(esdeDirName.toLowerCase())) continue;

      final system = await ScraperRepository.resolveSystemByFolderName(
        esdeDirName,
      );
      if (system == null) continue;

      await _recordEsdeMediaDir(
        esdeDirName,
        system['app_system_id']!,
        mediaDirectory: dir.path,
      );
      _log.i(
        'ES-DE import: linked art-only system "$esdeDirName" '
        '(no gamelist.xml) to ${system['app_system_id']}',
      );
    }
  }

  static Future<EsdeImportResult> _importSystem({
    required String esdeDirName,
    required String appSystemId,
    required File gamelistFile,
    required String mediaDirectory,
    required String descColumn,
    required EsdeImportResult accumulator,
    void Function(double fraction)? onGameProgress,
  }) async {
    var result = accumulator;
    XmlDocumentFragment doc;
    try {
      doc = XmlDocumentFragment.parse(
        utf8.decode(await gamelistFile.readAsBytes(), allowMalformed: true),
      );
    } catch (e) {
      _log.e('ES-DE import: failed to parse ${gamelistFile.path}: $e');
      return result._add(systemsSkipped: 1);
    }
    result = result._add(systemsMatched: 1);

    final db = await SqliteService.getDatabase();
    final romsByName = <String, Map<String, Object?>>{};
    for (final row in await db.query(
      'user_roms',
      columns: ['filename', 'is_favorite', 'last_played', 'play_time'],
      where: 'app_system_id = ?',
      whereArgs: [appSystemId],
    )) {
      final name = row['filename']?.toString();
      if (name == null || name.isEmpty) continue;
      romsByName.putIfAbsent(name.toLowerCase(), () => row);
    }
    final metaByName = <String, Map<String, Object?>>{};
    for (final row in await db.query(
      'user_screenscraper_metadata',
      where: 'app_system_id = ?',
      whereArgs: [appSystemId],
    )) {
      final name = row['filename']?.toString();
      if (name == null || name.isEmpty) continue;
      metaByName.putIfAbsent(name.toLowerCase(), () => row);
    }

    final batch = db.batch();
    final games = _selectGames(doc, mediaDirectory);
    for (var g = 0; g < games.length; g++) {
      if (g % 100 == 0) onGameProgress?.call(g / games.length);
      final game = games[g];
      final rawPath = _text(game, 'path');
      if (rawPath == null || rawPath.isEmpty) continue;

      final normalizedPath = rawPath.replaceAll('\\', '/');
      final filename = path.basename(normalizedPath);
      final mediaSubdir = _mediaSubdir(normalizedPath);

      // Metadata is still merged only for ROMs NeoStation has already scanned.
      // Fort's per-system ROM-path integration makes those scans ES-DE-aware;
      // keeping this join prevents a metadata import from manufacturing games
      // that are not actually accessible to NeoStation.
      final rom = romsByName[filename.toLowerCase()];
      if (rom == null) {
        result = result._add(gamesUnmatched: 1);
        continue;
      }

      final canonicalFilename =
          (rom['filename'] as String?)?.trim().isNotEmpty == true
          ? rom['filename'] as String
          : filename;

      final esdeMeta = <String, dynamic>{
        'real_name': _text(game, 'name'),
        descColumn: _text(game, 'desc'),
        'developer': _text(game, 'developer'),
        'publisher': _text(game, 'publisher'),
        'genre': _text(game, 'genre'),
        'players': _text(game, 'players'),
        'rating': _parseRating(_text(game, 'rating')),
        'release_date': _parseEsdeDateTime(
          _text(game, 'releasedate'),
        )?.toIso8601String(),
      };
      final existingMeta = metaByName[canonicalFilename.toLowerCase()];
      final metaWrite = ScraperRepository.buildEsdeMetadataWrite(
        appSystemId: appSystemId,
        filename: canonicalFilename,
        row: existingMeta,
        esde: esdeMeta,
        mediaSubdir: mediaSubdir,
      );
      if (metaWrite != null) {
        if (existingMeta == null) {
          batch.insert(
            'user_screenscraper_metadata',
            metaWrite,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } else {
          batch.update(
            'user_screenscraper_metadata',
            metaWrite,
            where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
            whereArgs: [appSystemId, canonicalFilename],
          );
        }
        result = result._add(gamesImported: 1);
      }

      final favorite = _flag(game, 'favorite');
      final lastPlayed = _parseEsdeDateTime(_text(game, 'lastplayed'));
      final update = <String, dynamic>{};

      final currentlyFavorite = (rom['is_favorite'] as int? ?? 0) == 1;
      if (favorite && !currentlyFavorite) update['is_favorite'] = 1;

      final curLastPlayed = rom['last_played'];
      final lastPlayedEmpty =
          curLastPlayed == null ||
          (curLastPlayed is String && curLastPlayed.trim().isEmpty) ||
          (curLastPlayed is num && curLastPlayed == 0);
      if (lastPlayed != null && lastPlayedEmpty) {
        update['last_played'] = lastPlayed.toIso8601String();
      }

      final esdePlayTime = int.tryParse(_text(game, 'playtime') ?? '');
      final curPlayTime =
          int.tryParse(rom['play_time']?.toString() ?? '0') ?? 0;
      if (esdePlayTime != null && esdePlayTime > 0 && curPlayTime == 0) {
        update['play_time'] = esdePlayTime;
      }

      if (update.isNotEmpty) {
        batch.update(
          'user_roms',
          update,
          where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
          whereArgs: [appSystemId, canonicalFilename],
        );
        result = result._add(statsUpdated: 1);
      }
    }

    await batch.commit(noResult: true);
    onGameProgress?.call(1.0);
    return result;
  }

  /// Persists the ES-DE system directory name used to resolve media. The value
  /// remains a logical name (for backward compatibility); [FileProvider]
  /// combines it with the current ES-DE MediaDirectory at read time.
  static Future<void> _recordEsdeMediaDir(
    String esdeDirName,
    String appSystemId, {
    required String mediaDirectory,
  }) async {
    final db = await SqliteService.getDatabase();
    final hasMedia = Directory(mediaDirectory).existsSync();

    final existing = await db.query(
      'user_system_settings',
      columns: ['app_system_id', 'esde_media_dir'],
      where: 'app_system_id = ?',
      whereArgs: [appSystemId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert('user_system_settings', {
        'app_system_id': appSystemId,
        'esde_media_dir': esdeDirName,
      });
      return;
    }

    final current = existing.first['esde_media_dir'];
    final currentEmpty =
        current == null || (current is String && current.trim().isEmpty);
    if (hasMedia || currentEmpty) {
      await db.update(
        'user_system_settings',
        {'esde_media_dir': esdeDirName},
        where: 'app_system_id = ?',
        whereArgs: [appSystemId],
      );
    }
  }

  static String _descriptionColumn(String lang) {
    const supported = {'en', 'es', 'fr', 'de', 'it', 'pt'};
    final code = lang.toLowerCase();
    return supported.contains(code) ? 'description_$code' : 'description_en';
  }

  static double? _parseRating(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final v = double.tryParse(raw.trim());
    if (v == null) return null;
    return v.clamp(0.0, 1.0) * 20.0;
  }

  static DateTime? _parseEsdeDateTime(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.length < 8) return null;
    try {
      final year = int.parse(s.substring(0, 4));
      final month = int.parse(s.substring(4, 6));
      final day = int.parse(s.substring(6, 8));
      if (year <= 1 || month < 1 || month > 12 || day < 1 || day > 31) {
        return null;
      }
      var hour = 0, minute = 0, second = 0;
      if (s.length >= 15 && s[8] == 'T') {
        hour = int.parse(s.substring(9, 11));
        minute = int.parse(s.substring(11, 13));
        second = int.parse(s.substring(13, 15));
      }
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  /// De-duplicates a gamelist's entries by ROM filename, preferring the entry
  /// whose mirrored ES-DE media subfolder actually contains artwork.
  static List<XmlElement> _selectGames(
    XmlNode doc,
    String systemMediaDirectory,
  ) {
    final chosen = <String, XmlElement>{};
    for (final game in doc.findAllElements('game')) {
      final rawPath = _text(game, 'path');
      if (rawPath == null || rawPath.isEmpty) continue;
      final normalized = rawPath.replaceAll('\\', '/');
      final key = path.basename(normalized).toLowerCase();

      final existing = chosen[key];
      if (existing == null) {
        chosen[key] = game;
        continue;
      }

      final filename = path.basename(normalized);
      final existingSubdir = _mediaSubdir(
        (_text(existing, 'path') ?? '').replaceAll('\\', '/'),
      );
      final newSubdir = _mediaSubdir(normalized);
      if (!_esdeMediaExists(
            systemMediaDirectory,
            filename,
            existingSubdir,
          ) &&
          _esdeMediaExists(systemMediaDirectory, filename, newSubdir)) {
        chosen[key] = game;
      }
    }
    return chosen.values.toList();
  }

  static bool _esdeMediaExists(
    String systemMediaDirectory,
    String filename,
    String subdir,
  ) {
    final dot = filename.lastIndexOf('.');
    final base = (dot > 0 ? filename.substring(0, dot) : filename)
        .toLowerCase();
    for (final category in const [
      'covers',
      'screenshots',
      'marquees',
      'fanart',
    ]) {
      final dir = path.join(systemMediaDirectory, category, subdir);
      if (_mediaIndex(dir).contains(base)) return true;
    }
    return false;
  }

  static final Map<String, Set<String>> _mediaIndexCache = {};

  static Set<String> _mediaIndex(String dir) {
    return _mediaIndexCache.putIfAbsent(dir, () {
      final names = <String>{};
      final directory = Directory(dir);
      if (!directory.existsSync()) return names;
      for (final entry in directory.listSync()) {
        if (entry is! File) continue;
        final name = path.basename(entry.path);
        final d = name.lastIndexOf('.');
        names.add((d > 0 ? name.substring(0, d) : name).toLowerCase());
      }
      return names;
    });
  }

  static String _mediaSubdir(String normalizedPath) {
    var p = normalizedPath;
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    final dir = path.dirname(p);
    if (dir == '.' || dir == '/' || dir.isEmpty) return '';
    return dir.startsWith('/') ? dir.substring(1) : dir;
  }

  static bool _flag(XmlElement parent, String tag) =>
      _text(parent, tag)?.toLowerCase() == 'true';

  static String? _text(XmlElement parent, String tag) {
    final el = parent.getElement(tag);
    if (el == null) return null;
    final t = el.innerText.trim();
    return t.isEmpty ? null : t;
  }

  // ── Test seams ──────────────────────────────────────────────────────────

  @visibleForTesting
  static double? parseRatingForTest(String? raw) => _parseRating(raw);

  @visibleForTesting
  static DateTime? parseEsdeDateTimeForTest(String? raw) =>
      _parseEsdeDateTime(raw);

  @visibleForTesting
  static String mediaSubdirForTest(String normalizedPath) =>
      _mediaSubdir(normalizedPath);

  @visibleForTesting
  static List<XmlElement> selectGamesForTest(
    XmlNode doc,
    String systemMediaDirectory,
  ) => _selectGames(doc, systemMediaDirectory);
}
