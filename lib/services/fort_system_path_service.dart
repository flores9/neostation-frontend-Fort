import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'config_service.dart';
import 'logger_service.dart';

/// Manual Fort path overrides for one NeoStation system.
///
/// Null fields mean "automatic" and therefore fall back to ES-DE/native
/// discovery. Values are intentionally independent: a user may keep ROMs on
/// internal storage, media on a microSD and the gamelist somewhere else.
class FortSystemPathOverride {
  final String? romDirectory;
  final String? mediaDirectory;
  final String? gamelistFile;

  const FortSystemPathOverride({
    this.romDirectory,
    this.mediaDirectory,
    this.gamelistFile,
  });

  bool get isEmpty =>
      romDirectory == null && mediaDirectory == null && gamelistFile == null;

  FortSystemPathOverride copyWith({
    String? romDirectory,
    String? mediaDirectory,
    String? gamelistFile,
    bool clearRomDirectory = false,
    bool clearMediaDirectory = false,
    bool clearGamelistFile = false,
  }) {
    return FortSystemPathOverride(
      romDirectory: clearRomDirectory ? null : romDirectory ?? this.romDirectory,
      mediaDirectory:
          clearMediaDirectory ? null : mediaDirectory ?? this.mediaDirectory,
      gamelistFile: clearGamelistFile ? null : gamelistFile ?? this.gamelistFile,
    );
  }

  Map<String, dynamic> toJson() => {
    if (romDirectory != null) 'romDirectory': romDirectory,
    if (mediaDirectory != null) 'mediaDirectory': mediaDirectory,
    if (gamelistFile != null) 'gamelistFile': gamelistFile,
  };

  factory FortSystemPathOverride.fromJson(Map<String, dynamic> json) {
    String? read(String key) {
      final raw = json[key]?.toString().trim();
      return raw == null || raw.isEmpty ? null : raw;
    }

    return FortSystemPathOverride(
      romDirectory: read('romDirectory'),
      mediaDirectory: read('mediaDirectory'),
      gamelistFile: read('gamelistFile'),
    );
  }
}

/// Fort-owned persistence for per-system path overrides.
///
/// Kept outside NeoStation's SQLite schema so this fork can continue pulling
/// upstream database migrations without claiming/colliding with migration
/// numbers. The JSON lives under NeoStation's configured user-data directory,
/// is versioned, human-readable and can be included in release/support backups.
class FortSystemPathService {
  FortSystemPathService._();

  static final _log = LoggerService.instance;
  static const int schemaVersion = 1;
  static Map<String, FortSystemPathOverride>? _cache;

  static Future<String> get configPath async {
    final userData = await ConfigService.getUserDataPath();
    return path.join(userData, 'fort', 'system-path-overrides.json');
  }

  static Future<Map<String, FortSystemPathOverride>> loadAll({
    bool forceReload = false,
  }) async {
    if (!forceReload && _cache != null) {
      return Map.unmodifiable(_cache!);
    }

    final file = File(await configPath);
    if (!await file.exists()) {
      _cache = <String, FortSystemPathOverride>{};
      return const {};
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Fort path config root is not an object');
      }
      final systems = decoded['systems'];
      final loaded = <String, FortSystemPathOverride>{};
      if (systems is Map) {
        for (final entry in systems.entries) {
          if (entry.value is! Map) continue;
          final override = FortSystemPathOverride.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          if (!override.isEmpty) {
            loaded[entry.key.toString().toLowerCase()] = override;
          }
        }
      }
      _cache = loaded;
      return Map.unmodifiable(loaded);
    } catch (e) {
      // Never replace a malformed file automatically. Returning an empty map
      // keeps NeoStation usable while preserving the file for diagnosis.
      _log.e('Fort path overrides could not be read: $e');
      _cache = <String, FortSystemPathOverride>{};
      return const {};
    }
  }

  static Future<FortSystemPathOverride> getForSystem(String systemFolder) async {
    final all = await loadAll();
    return all[systemFolder.toLowerCase()] ?? const FortSystemPathOverride();
  }

  static Future<void> saveForSystem(
    String systemFolder,
    FortSystemPathOverride value,
  ) async {
    final all = Map<String, FortSystemPathOverride>.from(await loadAll());
    final key = systemFolder.toLowerCase();
    if (value.isEmpty) {
      all.remove(key);
    } else {
      all[key] = value;
    }
    await _write(all);
  }

  static Future<void> clearSystem(String systemFolder) async {
    await saveForSystem(systemFolder, const FortSystemPathOverride());
  }

  static Future<void> _write(
    Map<String, FortSystemPathOverride> values,
  ) async {
    final file = File(await configPath);
    await file.parent.create(recursive: true);
    final payload = <String, dynamic>{
      'version': schemaVersion,
      'systems': {
        for (final entry in values.entries) entry.key: entry.value.toJson(),
      },
    };
    final encoder = const JsonEncoder.withIndent('  ');
    final temp = File('${file.path}.tmp');
    await temp.writeAsString('${encoder.convert(payload)}\n', flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
    _cache = Map<String, FortSystemPathOverride>.from(values);
  }

  /// Test/support hook used after replacing user-data or editing the JSON.
  static void invalidateCache() => _cache = null;
}
