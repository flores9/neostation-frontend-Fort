import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/logger_service.dart';
import '../models/system_model.dart';
import '../models/config_model.dart';
import '../models/emulator_model.dart';
import '../repositories/system_repository.dart';
import 'esde_config_resolver.dart';
import 'fort_system_path_service.dart';
import 'saf_directory_service.dart';

/// Service responsible for managing application paths, file I/O for configurations,
/// and discovery of emulation systems and standalone emulators.
class ConfigService {
  static final _log = LoggerService.instance;

  static String _getWindowsBasePath() {
    final exePath = Platform.resolvedExecutable;
    if (exePath.contains(r'build\windows') ||
        exePath.contains(r'build/windows')) {
      return Directory.current.path;
    }
    return path.dirname(exePath);
  }

  static const String _customPathKey = 'custom_user_data_path';
  static const Duration _androidStorageRetryDelay = Duration(seconds: 3);
  static const int _androidStorageMaxAttempts = 20;

  static Future<String>? _androidStorageWait;
  static bool _androidStorageUnavailable = false;
  static String? _unavailableStoragePath;
  static bool _useDefaultPathFallback = false;

  static bool get storageUnavailable => _androidStorageUnavailable;
  static String? get unavailableStoragePath => _unavailableStoragePath;

  static void resetStorageAvailability() {
    _androidStorageUnavailable = false;
    _unavailableStoragePath = null;
    _useDefaultPathFallback = false;
  }

  static void continueWithDefaultUserDataPath() {
    _log.w('User opted to continue with the default user-data path');
    _androidStorageUnavailable = false;
    _useDefaultPathFallback = true;
  }

  static Future<bool> ensureUserDataStorageReady() async {
    try {
      await getUserDataPath();
      return true;
    } catch (e) {
      _log.e('User-data storage is not ready: $e');
      return false;
    }
  }

  static Future<String> getUserDataPath() async {
    final prefs = await SharedPreferences.getInstance();
    final customPath = prefs.getString(_customPathKey);
    if (customPath != null &&
        customPath.isNotEmpty &&
        !_useDefaultPathFallback) {
      final dir = Directory(customPath);
      if (await dir.exists()) return customPath;

      if (Platform.isAndroid) {
        if (_androidStorageUnavailable &&
            _unavailableStoragePath == customPath) {
          throw StateError(
            'Configured user-data storage is unavailable: $customPath',
          );
        }
        return _androidStorageWait ??= _startAndroidStorageWait(customPath);
      }

      try {
        await dir.create(recursive: true);
        return customPath;
      } catch (e) {
        _log.w(
          'ConfigService: custom path "$customPath" inaccessible ($e). '
          'Falling back to default path.',
        );
        return getDefaultUserDataPath();
      }
    }
    return getDefaultUserDataPath();
  }

  static Future<String> _startAndroidStorageWait(String customPath) {
    final wait = _waitForAndroidStorage(customPath);
    unawaited(
      wait
          .then((_) {}, onError: (Object _) {})
          .whenComplete(() => _androidStorageWait = null),
    );
    return wait;
  }

  static Future<String> _waitForAndroidStorage(String customPath) async {
    final dir = Directory(customPath);
    for (var attempt = 1; attempt <= _androidStorageMaxAttempts; attempt++) {
      if (await dir.exists()) return customPath;
      if (await dir.parent.exists()) {
        await dir.create(recursive: true);
        return customPath;
      }
      if (attempt < _androidStorageMaxAttempts) {
        _log.i(
          'Waiting for custom user-data storage ($attempt/$_androidStorageMaxAttempts): $customPath',
        );
        await Future<void>.delayed(_androidStorageRetryDelay);
      }
    }

    _androidStorageUnavailable = true;
    _unavailableStoragePath = customPath;
    throw StateError(
      'Configured user-data storage is unavailable: $customPath',
    );
  }

  static Future<String> getDefaultUserDataPath() async {
    return _computeDefaultUserDataPath();
  }

  static Future<String> _computeDefaultUserDataPath() async {
    if (Platform.isAndroid) {
      final externalDir = await getExternalStorageDirectory();
      final dir = externalDir ?? await getApplicationDocumentsDirectory();
      final userDataPath = path.join(dir.path, 'user-data');
      final userDataDir = Directory(userDataPath);
      if (!await userDataDir.exists()) {
        try {
          await userDataDir.create(recursive: true);
        } catch (e) {
          _log.e('Failed to create Android user data directory: $e');
        }
      }
      return userDataPath;
    } else if (Platform.isIOS) {
      final directory = await getApplicationDocumentsDirectory();
      return path.join(directory.path, 'user-data');
    } else {
      String basePath;
      if (Platform.isLinux) {
        final executable = Platform.resolvedExecutable;
        if (executable.contains('/.mount_') ||
            executable.endsWith('.AppImage')) {
          final home = Platform.environment['HOME'];
          basePath = home != null
              ? path.join(home, '.neostation')
              : Directory.current.path;
        } else {
          basePath = Directory.current.path;
        }
      } else if (Platform.isMacOS) {
        final home = getRealHomePath();
        basePath = path.join(
          home,
          'Library',
          'Application Support',
          'com.neogamelab.neostation',
        );
      } else {
        basePath = _getWindowsBasePath();
      }
      return path.join(basePath, 'user-data');
    }
  }

  static String getRealHomePath() {
    if (Platform.isMacOS) {
      final user = Platform.environment['USER'];
      if (user != null && user.isNotEmpty) return '/Users/$user';
    }
    return Platform.environment['HOME'] ?? '';
  }

  static String resolvePath(String pathStr) {
    if (pathStr.isEmpty) return pathStr;
    String resolved = pathStr;
    if (resolved.contains('{HOME}')) {
      resolved = resolved.replaceFirst('{HOME}', getRealHomePath());
    }
    if (resolved.contains('{USERPROFILE}')) {
      resolved = resolved.replaceFirst(
        '{USERPROFILE}',
        Platform.environment['USERPROFILE'] ?? getRealHomePath(),
      );
    }
    return resolved;
  }

  /// Returns the exact Fort/ES-DE ROM directory for [system], if one should
  /// override NeoStation's global ROM-root discovery.
  static Future<String?> getFortSystemRomDirectory(
    SystemModel system, {
    String? esdeRoot,
  }) async {
    final manual = await FortSystemPathService.getForSystem(system.folderName);
    if (manual.romDirectory != null) return manual.romDirectory;
    return _getAutomaticEsdeRomDirectory(system, esdeRoot: esdeRoot);
  }

  static Future<String?> _getAutomaticEsdeRomDirectory(
    SystemModel system, {
    String? esdeRoot,
  }) async {
    final root = esdeRoot?.trim();
    if (root == null || root.isEmpty) return null;

    try {
      final resolved = await EsdeConfigResolver.load(root);
      final names = <String>{system.folderName, ...system.folders};
      for (final name in names) {
        final explicit = resolved.customSystemRomPaths[name.toLowerCase()];
        if (explicit != null && explicit.isNotEmpty) return explicit;
      }

      if (resolved.settings.romDirectory != null) {
        for (final name in names) {
          final candidate = resolved.forSystem(name).romDirectory;
          if (candidate != null && await _pathExists(candidate)) {
            return candidate;
          }
        }
      }
    } catch (e) {
      _log.w('Fort ROM path resolution failed for ${system.folderName}: $e');
    }
    return null;
  }

  static Future<bool> hasFortRomSources({String? esdeRoot}) async {
    final overrides = await FortSystemPathService.loadAll();
    if (overrides.values.any((v) => v.romDirectory != null)) return true;

    final root = esdeRoot?.trim();
    if (root == null || root.isEmpty) return false;
    try {
      final resolved = await EsdeConfigResolver.load(root);
      return resolved.customSystemRomPaths.isNotEmpty ||
          resolved.settings.romDirectory != null;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isFortRomDirectoryAccessible(String directory) async {
    if (directory.startsWith('content://')) {
      if (!Platform.isAndroid) return false;
      try {
        return await SafDirectoryService.hasPermission(directory);
      } catch (_) {
        return false;
      }
    }
    return _pathExists(directory);
  }

  static Future<bool> _pathExists(String candidate) async {
    if (candidate.startsWith('content://')) {
      if (!Platform.isAndroid) return false;
      try {
        return await SafDirectoryService.hasPermission(candidate);
      } catch (_) {
        return false;
      }
    }
    try {
      return await Directory(candidate).exists();
    } catch (_) {
      return false;
    }
  }

  /// UI/support snapshot for the three independent per-system Fort paths.
  /// Keys ending in `Manual` contain the persisted override; keys ending in
  /// `Auto` contain the current ES-DE-derived value when one can be resolved.
  static Future<Map<String, String?>> getFortSystemPathSnapshot(
    SystemModel system, {
    String? esdeRoot,
  }) async {
    final manual = await FortSystemPathService.getForSystem(system.folderName);
    String? autoRom;
    String? autoMedia;
    String? autoGamelist;

    final root = esdeRoot?.trim();
    if (root != null && root.isNotEmpty) {
      try {
        final resolved = await EsdeConfigResolver.load(root);
        final names = <String>{system.folderName, ...system.folders};
        String chosenName = system.folderName;

        for (final name in names) {
          if (resolved.customSystemRomPaths.containsKey(name.toLowerCase())) {
            chosenName = name;
            break;
          }
          final candidate = resolved.forSystem(name);
          if (candidate.firstExistingGamelist != null) {
            chosenName = name;
            break;
          }
        }

        final auto = resolved.forSystem(chosenName);
        autoRom = await _getAutomaticEsdeRomDirectory(system, esdeRoot: root);
        autoMedia = auto.mediaDirectory;
        autoGamelist =
            auto.firstExistingGamelist ??
            (auto.gamelistCandidates.isEmpty
                ? null
                : auto.gamelistCandidates.first);
      } catch (e) {
        _log.w('Fort path snapshot failed for ${system.folderName}: $e');
      }
    }

    return {
      'romManual': manual.romDirectory,
      'mediaManual': manual.mediaDirectory,
      'gamelistManual': manual.gamelistFile,
      'romAuto': autoRom,
      'mediaAuto': autoMedia,
      'gamelistAuto': autoGamelist,
      'romEffective': manual.romDirectory ?? autoRom,
      'mediaEffective': manual.mediaDirectory ?? autoMedia,
      'gamelistEffective': manual.gamelistFile ?? autoGamelist,
    };
  }

  static Future<void> setFortSystemRomOverride(
    String systemFolder,
    String? value,
  ) async {
    final current = await FortSystemPathService.getForSystem(systemFolder);
    await FortSystemPathService.saveForSystem(
      systemFolder,
      value == null || value.trim().isEmpty
          ? current.copyWith(clearRomDirectory: true)
          : current.copyWith(romDirectory: value.trim()),
    );
  }

  static Future<void> setFortSystemMediaOverride(
    String systemFolder,
    String? value,
  ) async {
    final current = await FortSystemPathService.getForSystem(systemFolder);
    await FortSystemPathService.saveForSystem(
      systemFolder,
      value == null || value.trim().isEmpty
          ? current.copyWith(clearMediaDirectory: true)
          : current.copyWith(mediaDirectory: value.trim()),
    );
  }

  static Future<void> setFortSystemGamelistOverride(
    String systemFolder,
    String? value,
  ) async {
    final current = await FortSystemPathService.getForSystem(systemFolder);
    await FortSystemPathService.saveForSystem(
      systemFolder,
      value == null || value.trim().isEmpty
          ? current.copyWith(clearGamelistFile: true)
          : current.copyWith(gamelistFile: value.trim()),
    );
  }

  static Future<String> getMediaPath() async {
    if (Platform.isAndroid) {
      final userDataPath = await getUserDataPath();
      final mediaPath = path.join(userDataPath, 'media');
      final mediaDir = Directory(mediaPath);
      if (!await mediaDir.exists()) {
        try {
          await mediaDir.create(recursive: true);
        } catch (e) {
          _log.e('Failed to create Android media directory: $e');
        }
      }
      return mediaPath;
    } else if (Platform.isIOS) {
      final directory = await getApplicationDocumentsDirectory();
      return path.join(directory.path, 'media');
    } else {
      final prefs = await SharedPreferences.getInstance();
      final customPath = prefs.getString(_customPathKey);
      if (customPath != null && customPath.isNotEmpty) {
        return path.join(customPath, 'media');
      }

      String basePath;
      if (Platform.isLinux) {
        final executable = Platform.resolvedExecutable;
        if (executable.contains('/.mount_') ||
            executable.endsWith('.AppImage')) {
          final home = Platform.environment['HOME'];
          basePath = home != null
              ? path.join(home, '.neostation')
              : Directory.current.path;
        } else {
          basePath = Directory.current.path;
        }
      } else if (Platform.isMacOS) {
        final home = getRealHomePath();
        basePath = path.join(
          home,
          'Library',
          'Application Support',
          'com.neogamelab.neostation',
        );
      } else {
        basePath = _getWindowsBasePath();
        return path.join(basePath, 'user-data', 'media');
      }
      return path.join(basePath, 'media');
    }
  }

  static Future<String> getConfigFilePath() async {
    final userDataPath = await getUserDataPath();
    return path.join(userDataPath, 'config.json');
  }

  static Future<String> getLogFilePath() async {
    final userDataPath = await getUserDataPath();
    return path.join(userDataPath, 'app.log');
  }

  static Future<ConfigModel> loadConfig() async {
    try {
      final configPath = await getConfigFilePath();
      final file = File(configPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        return ConfigModel.fromJson(json);
      }
    } catch (e) {
      _log.e('Error loading configuration: $e');
    }
    return ConfigModel.empty;
  }

  static Future<void> saveConfig(ConfigModel config) async {
    try {
      final configPath = await getConfigFilePath();
      final file = File(configPath);
      await file.parent.create(recursive: true);
      final json = jsonEncode(config.toJson());
      await file.writeAsString(json);
    } catch (e) {
      _log.e('Error saving configuration: $e');
      rethrow;
    }
  }

  static Future<List<SystemModel>> loadAvailableSystems() async {
    try {
      final content = await rootBundle.loadString(
        'assets/system-data/systems.json',
      );
      final List<dynamic> json = jsonDecode(content);
      return json.map((system) => SystemModel.fromJson(system)).toList();
    } catch (e) {
      _log.e('Error loading available systems: $e');
      return [];
    }
  }

  static Future<Map<String, EmulatorModel>> loadAvailableEmulators() async {
    try {
      final content = await rootBundle.loadString(
        'assets/system-data/emulator.json',
      );
      final Map<String, dynamic> json = jsonDecode(content);
      final emulatorsData = json['emulators'] as Map<String, dynamic>;
      final Map<String, EmulatorModel> emulators = {};
      for (final entry in emulatorsData.entries) {
        emulators[entry.key] = EmulatorModel.fromJson(
          entry.key,
          entry.value as Map<String, dynamic>,
        );
      }
      return emulators;
    } catch (e) {
      _log.e('Error loading available emulators: $e');
      return {};
    }
  }

  static Future<List<SystemModel>> detectSystems({
    required List<String> romFolders,
    required List<SystemModel> availableSystems,
  }) async {
    final Map<String, SystemModel> detectedSystemsMap = {};
    try {
      for (final romFolder in romFolders) {
        final romDir = Directory(romFolder);
        if (!await romDir.exists()) continue;
        final entities = await romDir
            .list()
            .where((entity) => entity is Directory)
            .toList();
        for (final entity in entities) {
          final folderName = path.basename(entity.path);
          final matchingSystem = availableSystems.firstWhere(
            (system) =>
                system.folderName.toLowerCase() == folderName.toLowerCase(),
            orElse: () => SystemModel(
              folderName: folderName,
              realName: 'Unknown System',
              iconImage: '/assets/images/systems/unknown-icon.png',
              color: '#607d8b',
            ),
          );
          final romCount = await _countRomsInFolder(
            entity.path,
            matchingSystem.id,
          );
          final existing = detectedSystemsMap[matchingSystem.id];
          if (existing != null) {
            detectedSystemsMap[matchingSystem.id!] = existing.copyWith(
              romCount: existing.romCount + romCount,
            );
          } else {
            detectedSystemsMap[matchingSystem.id!] = matchingSystem.copyWith(
              romCount: romCount,
              detected: true,
            );
          }
        }
      }
      return detectedSystemsMap.values.toList();
    } catch (e) {
      _log.e('Error detecting systems: $e');
      return [];
    }
  }

  static Future<int> _countRomsInFolder(
    String folderPath, [
    String? systemId,
  ]) async {
    try {
      final folder = Directory(folderPath);
      if (!await folder.exists()) return 0;
      Set<String> romExtensions;
      if (systemId != null) {
        romExtensions = await SystemRepository.getExtensionsForSystem(systemId);
      } else {
        romExtensions = await SystemRepository.getAllValidExtensions();
      }
      int count = 0;
      await for (final entity in folder.list(recursive: true)) {
        if (entity is File) {
          final extension = path.extension(entity.path).toLowerCase();
          if (romExtensions.contains(extension)) count++;
        }
      }
      return count;
    } catch (e) {
      _log.e('Error counting ROMs in $folderPath: $e');
      return 0;
    }
  }

  static Future<Map<String, EmulatorModel>> detectEmulators({
    required Map<String, EmulatorModel> availableEmulators,
  }) async {
    final Map<String, EmulatorModel> detectedEmulators = {};
    try {
      for (final entry in availableEmulators.entries) {
        final emulatorName = entry.key;
        final emulator = entry.value;
        String? detectedPath;
        final platform = _getCurrentPlatform();
        final possiblePaths = emulator.possiblePaths[platform] ?? [];
        for (final possiblePath in possiblePaths) {
          final file = File(possiblePath);
          if (await file.exists()) {
            detectedPath = possiblePath;
            break;
          }
        }
        detectedEmulators[emulatorName] = emulator.copyWith(
          path: detectedPath ?? '',
          detected: detectedPath != null,
          lastDetection: detectedPath != null ? DateTime.now() : null,
        );
      }
      return detectedEmulators;
    } catch (e) {
      _log.e('Error detecting emulators: $e');
      return detectedEmulators;
    }
  }

  static String _getCurrentPlatform() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    return 'unknown';
  }
}
