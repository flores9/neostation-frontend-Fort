import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../data/datasources/sqlite_service.dart';
import '../repositories/scraper_repository.dart';
import 'esde_config_resolver.dart';
import 'fort_esde_library_service.dart';
import 'fort_system_path_service.dart';
import 'logger_service.dart';

class EsdeImportResult {
  final int systemsMatched;
  final int systemsUnmatched;
  final int systemsSkipped;
  final int gamesImported;
  final int gamesUnmatched;
  final int statsUpdated;
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
      gamelistDirFound: gamelistsDirFound,
    );
  }
}

class _EsdeGamelistSource {
  final String esdeSystemName;
  final File file;
  final String mediaDirectory;
  final bool manual;

  const _EsdeGamelistSource({
    required this.esdeSystemName,
    required this.file,
    required this.mediaDirectory,
    this.manual = false,
  });
}

/// Imports metadata and wires up read-only fallback artwork from ES-DE.
class EsdeImportService {
  static final _log = LoggerService.instance;

  static const Set<String> _esdeMediaCategories = {
    '3dboxes',
    'backcovers',
    'covers',
    'fanart',
    'manuals',
    'marquees',
    'miximages',
    'physicalmedia',
    'screenshots',
    'titlescreens',
    'videos',
  };

  static Future<EsdeImportResult> import(
    String esdeRoot, {
    void Function(double progress, String label)? onProgress,
  }) async {
    var result = const EsdeImportResult();
    _mediaIndexCache.clear();

    final resolved = await EsdeConfigResolver.load(esdeRoot);
    await FortEsdeLibraryService.ensureSchema();
    await FortEsdeLibraryService.reconcileRomProvenance();
    final sources = await _discoverGamelists(resolved);
    if (sources.isEmpty) {
      _log.w(
        'ES-DE import: no central, ROM-local or manual gamelist.xml found at $esdeRoot',
      );
      return const EsdeImportResult(gamelistsDirFound: false);
    }

    final importedDirs = <String>{};
    final preferredLang = await ScraperRepository.getPreferredLanguage();
    final descColumn = _descriptionColumn(preferredLang);
    final systemsWithManualGamelist = <String>{};

    final sourceProfiles = <String, Set<String>>{};
    for (final source in sources) {
      final system = await ScraperRepository.resolveSystemByFolderName(
        source.esdeSystemName,
      );
      final profileId = system?['app_system_id']?.toString();
      if (profileId == null || profileId.isEmpty) continue;
      sourceProfiles
          .putIfAbsent(profileId, () => <String>{})
          .add(source.esdeSystemName.toLowerCase());
    }

    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      final esdeDirName = source.esdeSystemName;
      final sourceKey = esdeDirName.toLowerCase();
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
      if (!source.manual && systemsWithManualGamelist.contains(sourceKey)) {
        _log.i(
          'ES-DE import: automatic gamelist for "$esdeDirName" skipped '
          'because its Fort manual gamelist already won',
        );
        continue;
      }
      if (source.manual) systemsWithManualGamelist.add(sourceKey);

      final definition = resolved.systems[sourceKey];
      final sourcePaths = resolved.forSystem(esdeDirName);
      await FortEsdeLibraryService.upsertPlatform(
        esdeSystemName: esdeDirName,
        appSystemId: appSystemId,
        displayName: definition?.fullName ?? esdeDirName,
        romDirectory: sourcePaths.romDirectory,
        mediaDirectory: source.mediaDirectory,
        gamelistFile: source.file.path,
        theme: definition?.theme,
        platformTags: definition?.platformTags ?? const [],
      );
      await FortEsdeLibraryService.reconcileRomProvenance();

      final matchedBefore = result.systemsMatched;
      result = await _importSystem(
        esdeDirName: esdeDirName,
        appSystemId: appSystemId,
        gamelistFile: source.file,
        mediaDirectory: source.mediaDirectory,
        descColumn: descColumn,
        accumulator: result,
        allowUntaggedFallback: (sourceProfiles[appSystemId]?.length ?? 0) <= 1,
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
        importedDirs.add(sourceKey);
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

  /// Discovers gamelists only from concrete ES-DE/user evidence.
  ///
  /// NeoStation's app_systems/app_system_folders aliases deliberately do not
  /// participate here: those names describe emulator compatibility, not what
  /// platforms actually exist in the ES-DE library. ROM-local gamelists remain
  /// supported by enumerating the configured ES-DE ROMDirectory itself.
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

    names.addAll(resolved.systems.keys);
    names.addAll(resolved.customSystemRomPaths.keys);

    final romRootPath = resolved.settings.romDirectory;
    if (romRootPath != null && romRootPath.isNotEmpty) {
      final romRoot = Directory(romRootPath);
      if (romRoot.existsSync()) {
        try {
          for (final dir in romRoot.listSync().whereType<Directory>()) {
            if (File(path.join(dir.path, 'gamelist.xml')).existsSync()) {
              names.add(path.basename(dir.path));
            }
          }
        } catch (e) {
          _log.w('ES-DE import: could not enumerate ROM-local gamelists: $e');
        }
      }
    }

    final deduped = <String, _EsdeGamelistSource>{};
    final overrides = await FortSystemPathService.loadAll();
    for (final entry in overrides.entries) {
      final manualGamelist = entry.value.gamelistFile;
      if (manualGamelist == null || manualGamelist.trim().isEmpty) continue;
      final file = File(manualGamelist.trim());
      if (!file.existsSync()) {
        _log.w(
          'Fort manual gamelist for ${entry.key} is unavailable: ${file.path}',
        );
        continue;
      }
      final auto = resolved.forSystem(entry.key);
      final media = entry.value.mediaDirectory ?? auto.mediaDirectory;
      final canonical = path.normalize(file.path).toLowerCase();
      deduped[canonical] = _EsdeGamelistSource(
        esdeSystemName: entry.key,
        file: file,
        mediaDirectory: media,
        manual: true,
      );
      names.add(entry.key);
    }

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
          mediaDirectory:
              overrides[name.toLowerCase()]?.mediaDirectory ??
              paths.mediaDirectory,
        ),
      );
    }

    final sources = deduped.values.toList()
      ..sort((a, b) {
        if (a.manual != b.manual) return a.manual ? -1 : 1;
        return a.esdeSystemName.compareTo(b.esdeSystemName);
      });
    return sources;
  }

  static Future<int> reset() async {
    final db = await SqliteService.getDatabase();
    final deleted = await db.delete(
      'user_screenscraper_metadata',
      where: 'esde_imported = 1 AND is_fully_scraped = 0',
    );
    await db.update('user_system_settings', {
      'esde_media_dir': null,
    }, where: 'esde_media_dir IS NOT NULL');
    await FortEsdeLibraryService.reset();
    _log.i('ES-DE reset: cleared $deleted metadata rows and media dirs');
    return deleted;
  }

  static Future<void> _linkMediaOnlySystems(
    EsdeResolvedConfig resolved,
    Set<String> importedDirs,
  ) async {
    final mediaRoot = Directory(resolved.mediaRoot);
    if (!mediaRoot.existsSync()) return;

    final overrides = await FortSystemPathService.loadAll();
    for (final dir in mediaRoot.listSync().whereType<Directory>()) {
      if (!_looksLikeEsdeMediaSystemDirectory(dir)) continue;

      final esdeDirName = path.basename(dir.path);
      if (importedDirs.contains(esdeDirName.toLowerCase())) continue;

      final system = await ScraperRepository.resolveSystemByFolderName(
        esdeDirName,
      );
      if (system == null) continue;

      final effectiveMedia =
          overrides[esdeDirName.toLowerCase()]?.mediaDirectory ?? dir.path;
      final definition = resolved.systems[esdeDirName.toLowerCase()];
      final sourcePaths = resolved.forSystem(esdeDirName);
      await FortEsdeLibraryService.upsertPlatform(
        esdeSystemName: esdeDirName,
        appSystemId: system['app_system_id']!,
        displayName: definition?.fullName ?? esdeDirName,
        romDirectory: sourcePaths.romDirectory,
        mediaDirectory: effectiveMedia,
        gamelistFile: sourcePaths.firstExistingGamelist,
        theme: definition?.theme,
        platformTags: definition?.platformTags ?? const [],
      );
      await _recordEsdeMediaDir(
        esdeDirName,
        system['app_system_id']!,
        mediaDirectory: effectiveMedia,
      );
      _log.i(
        'ES-DE import: linked art-only system "$esdeDirName" '
        '(no gamelist.xml) to ${system['app_system_id']}',
      );
    }
  }

  static bool _looksLikeEsdeMediaSystemDirectory(Directory directory) {
    try {
      for (final child in directory.listSync().whereType<Directory>()) {
        if (_esdeMediaCategories.contains(path.basename(child.path).toLowerCase())) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static Future<EsdeImportResult> _importSystem({
    required String esdeDirName,
    required String appSystemId,
    required File gamelistFile,
    required String mediaDirectory,
    required String descColumn,
    required EsdeImportResult accumulator,
    required bool allowUntaggedFallback,
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
    final sourceColumn = FortEsdeLibraryService.romSourceColumn;
    final romSourcePredicate = allowUntaggedFallback
        ? '($sourceColumn = ? COLLATE NOCASE OR '
              '$sourceColumn IS NULL OR length($sourceColumn) = 0)'
        : '$sourceColumn = ? COLLATE NOCASE';
    final romsByName = <String, Map<String, Object?>>{};
    for (final row in await db.query(
      'user_roms',
      columns: [
        'filename',
        'rom_path',
        'is_favorite',
        'last_played',
        'play_time',
      ],
      where: 'app_system_id = ? AND $romSourcePredicate',
      whereArgs: [appSystemId, esdeDirName],
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

      final rom = romsByName[filename.toLowerCase()];
      if (rom == null) {
        result = result._add(gamesUnmatched: 1);
        continue;
      }

      final canonicalFilename =
          (rom['filename'] as String?)?.trim().isNotEmpty == true
          ? rom['filename'] as String
          : filename;
      final romPath = rom['rom_path']?.toString();

      final siblingRows = await db.rawQuery(
        'SELECT COUNT(DISTINCT ${FortEsdeLibraryService.romSourceColumn}) AS c '
        'FROM user_roms WHERE app_system_id = ? '
        'AND filename = ? COLLATE NOCASE '
        'AND ${FortEsdeLibraryService.romSourceColumn} IS NOT NULL',
        [appSystemId, canonicalFilename],
      );
      final siblingCount = siblingRows.isEmpty
          ? 0
          : int.tryParse(siblingRows.first['c']?.toString() ?? '0') ?? 0;

      if (siblingCount <= 1) {
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
      } else {
        _log.w(
          'ES-DE metadata skipped for ambiguous sibling filename '
          '$appSystemId/$canonicalFilename (source=$esdeDirName)',
        );
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

      if (update.isNotEmpty && romPath != null && romPath.isNotEmpty) {
        batch.update(
          'user_roms',
          update,
          where: 'rom_path = ?',
          whereArgs: [romPath],
        );
        result = result._add(statsUpdated: 1);
      }
    }

    await batch.commit(noResult: true);
    onGameProgress?.call(1.0);
    return result;
  }

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
      if (!_esdeMediaExists(systemMediaDirectory, filename, existingSubdir) &&
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
    String esdeRoot,
    String esdeDirName,
  ) => _selectGames(doc, path.join(esdeRoot, 'downloaded_media', esdeDirName));
}
