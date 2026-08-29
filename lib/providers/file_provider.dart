import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/esde_config_resolver.dart';
import 'package:neostation/services/fort_system_path_service.dart';
import 'package:neostation/services/logger_service.dart';

/// Provider responsible for abstracting filesystem access across Android and Desktop platforms.
class FileProvider extends ChangeNotifier {
  static const String userDataFolder = 'user-data';
  static const String mediaFolder = 'media';
  static const String videosFolder = 'videos';
  static const String screenshotsFolder = 'screenshots';

  static final _log = LoggerService.instance;

  String? _userDataPath;
  String? _mediaPath;
  String? _documentsPath;
  bool _isInitialized = false;
  Map<String, Set<String>> _systemExtensions = {};

  String? _esdeRoot;
  Map<String, String> _esdeSystemMediaPaths = {};
  Map<String, String> _manualSystemMediaPaths = {};
  Map<String, String> _esdeMediaSubdirs = {};

  static String _esdeSubdirKey(String systemFolder, String romBase) =>
      '${systemFolder.toLowerCase()}\u0000${romBase.toLowerCase()}';

  static const Map<String, List<String>> _esdeMediaCategories = {
    'box2d': ['covers', '3dboxes'],
    'wheels': ['marquees'],
    'screenshots': ['screenshots', 'titlescreens'],
    'fanarts': ['fanart'],
    'videos': ['videos'],
  };

  static const List<String> _esdeMediaExtensions = ['png', 'jpg', 'webp'];
  static const List<String> _esdeVideoExtensions = [
    'mp4',
    'webm',
    'mkv',
    'avi',
    'wmv',
    'mov',
    'm4v',
  ];

  String? get userDataPath => _userDataPath;
  String? get mediaPath => _mediaPath;
  String? get documentsPath => _documentsPath;
  bool get isInitialized => _isInitialized;

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final appSupportDir = await getApplicationSupportDirectory();
        _documentsPath = appSupportDir.path;
        _userDataPath = appSupportDir.path;

        if (Platform.isAndroid) {
          final userDataPath = await ConfigService.getUserDataPath();
          _mediaPath = userDataPath;
        } else {
          _mediaPath = appSupportDir.path;
        }
      } else {
        final userDataPath = await ConfigService.getUserDataPath();
        final userDataDir = Directory(userDataPath);
        _userDataPath = userDataDir.path;

        final fullMediaPath = await ConfigService.getMediaPath();
        _mediaPath = path.dirname(fullMediaPath);
        _documentsPath = path.dirname(userDataDir.path);
      }

      if (_userDataPath != null) {
        final userDataDir = Directory(_userDataPath!);
        if (!await userDataDir.exists()) {
          await userDataDir.create(recursive: true);
        }
      }

      if (_mediaPath != null) {
        final mediaDir = Directory(_mediaPath!);
        if (!await mediaDir.exists()) {
          await mediaDir.create(recursive: true);
        }
      }

      _systemExtensions = await SystemRepository.getSystemExtensionsMap();
      await _loadEsdeConfig();
      _isInitialized = true;
      notifyListeners();
    } catch (e) {
      _log.e('FileProvider: Error initializing: $e');
      _userDataPath = null;
      _mediaPath = null;
      _documentsPath = null;
      _isInitialized = false;
      notifyListeners();
    }
  }

  String _stripRomExtension(String romName, [String? systemFolderName]) {
    final validExtensions = systemFolderName != null
        ? _systemExtensions[systemFolderName]
        : null;
    return stripRomExtension(romName, validExtensions);
  }

  static const Set<String> _commonRomExts = {
    'zip',
    '7z',
    'rar',
    'iso',
    'bin',
    'cue',
    'chd',
    'nes',
    'sfc',
    'smc',
    'gba',
    'gbc',
    'gb',
    'n64',
    'z64',
    'v64',
    'nds',
    '3ds',
    'cia',
    'nsp',
    'xci',
    'nca',
    'nro',
    'nso',
    'rvz',
    'wbfs',
    'gcm',
    'rpx',
  };

  static String stripRomExtension(
    String romName, [
    Set<String>? validExtensions,
  ]) {
    if (!romName.contains('.')) return romName;
    final lastDot = romName.lastIndexOf('.');
    final ext = romName.substring(lastDot + 1).toLowerCase();
    if (validExtensions != null && validExtensions.contains(ext)) {
      return romName.substring(0, lastDot);
    }
    final isVersion =
        RegExp(r'^\d+$').hasMatch(ext) || RegExp(r'^v\d+').hasMatch(ext);
    if (isVersion) return romName;
    if (_commonRomExts.contains(ext)) return romName.substring(0, lastDot);
    if (ext.length <= 4 && !ext.contains(' ')) {
      return romName.substring(0, lastDot);
    }
    return romName;
  }

  String getVideoPath(String systemFolderName, String romName) {
    final baseName = _stripRomExtension(romName, systemFolderName);
    if (!_isInitialized || _mediaPath == null) {
      return path.join(
        mediaFolder,
        systemFolderName,
        videosFolder,
        '$baseName.mp4',
      );
    }
    return path.join(
      _mediaPath!,
      mediaFolder,
      systemFolderName,
      videosFolder,
      '$baseName.mp4',
    );
  }

  String getScreenshotPath(String systemFolderName, String romName) {
    final baseName = _stripRomExtension(romName, systemFolderName);
    if (!_isInitialized || _mediaPath == null) {
      return path.join(
        mediaFolder,
        systemFolderName,
        screenshotsFolder,
        '$baseName.png',
      );
    }
    return path.join(
      _mediaPath!,
      mediaFolder,
      systemFolderName,
      screenshotsFolder,
      '$baseName.png',
    );
  }

  String getMediaPath(
    String systemFolderName,
    String imageType,
    String romName,
    String extension,
  ) {
    final baseName = _stripRomExtension(romName, systemFolderName);
    if (!_isInitialized || _mediaPath == null) {
      return path.join(
        mediaFolder,
        systemFolderName,
        imageType,
        '$baseName.$extension',
      );
    }
    return path.join(
      _mediaPath!,
      mediaFolder,
      systemFolderName,
      imageType,
      '$baseName.$extension',
    );
  }

  String getAbsolutePath(String relativePath) {
    if (!_isInitialized || _userDataPath == null) {
      return path.join(userDataFolder, relativePath);
    }
    return path.join(_userDataPath!, relativePath);
  }

  String getRomPath(String systemFolderName, String romName) {
    if (!_isInitialized || _userDataPath == null) {
      return path.join(
        userDataFolder,
        'roms',
        systemFolderName,
        '$romName.zip',
      );
    }
    return path.join(_userDataPath!, 'roms', systemFolderName, '$romName.zip');
  }

  Future<bool> fileExists(String filePath) async {
    try {
      return await File(filePath).exists();
    } catch (e) {
      _log.e('Error checking file existence $filePath: $e');
      return false;
    }
  }

  Future<void> ensureDirectoryExists(String filePath) async {
    try {
      final directory = Directory(path.dirname(filePath));
      if (!await directory.exists()) await directory.create(recursive: true);
    } catch (e) {
      _log.e('Error creating directory for $filePath: $e');
    }
  }

  Future<List<FileSystemEntity>> getFilesInDirectory(
    String directoryPath,
  ) async {
    try {
      final directory = Directory(directoryPath);
      return await directory.exists() ? await directory.list().toList() : [];
    } catch (e) {
      _log.e('Error listing files in $directoryPath: $e');
      return [];
    }
  }

  Future<int> getFileSize(String filePath) async {
    try {
      final file = File(filePath);
      return await file.exists() ? await file.length() : 0;
    } catch (e) {
      _log.e('Error getting file size $filePath: $e');
      return 0;
    }
  }

  Future<bool> copyFile(String sourcePath, String destinationPath) async {
    try {
      await ensureDirectoryExists(destinationPath);
      await File(sourcePath).copy(destinationPath);
      return true;
    } catch (e) {
      _log.e('Error copying file $sourcePath to $destinationPath: $e');
      return false;
    }
  }

  Future<bool> deleteFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      _log.e('Error deleting file $filePath: $e');
      return false;
    }
  }

  String getDocumentsPath() => _documentsPath ?? Directory.current.path;
  String getAppDirectoryPath() => _userDataPath ?? userDataFolder;

  String getMediaDirectoryPath() {
    if (!_isInitialized || _mediaPath == null) return mediaFolder;
    return path.join(_mediaPath!, mediaFolder);
  }

  Future<void> _loadEsdeConfig() async {
    try {
      final overrides = await FortSystemPathService.loadAll(forceReload: true);
      _manualSystemMediaPaths = {
        for (final entry in overrides.entries)
          if (entry.value.mediaDirectory != null)
            entry.key: entry.value.mediaDirectory!,
      };

      final db = await SqliteService.getDatabase();
      final cfg = await db.query(
        'user_config',
        columns: ['esde_folder_path'],
        limit: 1,
      );
      final rootRaw = cfg.isNotEmpty
          ? cfg.first['esde_folder_path']?.toString()
          : null;
      _esdeRoot = (rootRaw != null && rootRaw.trim().isNotEmpty)
          ? rootRaw.trim()
          : null;

      final map = <String, String>{};
      if (_esdeRoot != null) {
        final resolved = await EsdeConfigResolver.load(_esdeRoot!);
        final rows = await db.rawQuery('''
          SELECT s.folder_name AS folder_name, ss.esde_media_dir AS esde_media_dir
          FROM user_system_settings ss
          JOIN app_systems s ON s.id = ss.app_system_id
          WHERE ss.esde_media_dir IS NOT NULL AND ss.esde_media_dir != ''
        ''');
        for (final r in rows) {
          final fn = r['folder_name']?.toString();
          final esdeSystem = r['esde_media_dir']?.toString();
          if (fn == null || esdeSystem == null || esdeSystem.isEmpty) continue;
          map[fn] = resolved.forSystem(esdeSystem).mediaDirectory;
        }
      }
      _esdeSystemMediaPaths = map;

      final subdirs = <String, String>{};
      if (_esdeRoot != null) {
        final rows = await db.rawQuery('''
          SELECT s.folder_name AS folder_name, m.filename AS filename,
                 m.esde_media_subdir AS subdir
          FROM user_screenscraper_metadata m
          JOIN app_systems s ON s.id = m.app_system_id
          WHERE m.esde_media_subdir IS NOT NULL AND m.esde_media_subdir != ''
        ''');
        for (final r in rows) {
          final fn = r['folder_name']?.toString();
          final file = r['filename']?.toString();
          final sub = r['subdir']?.toString();
          if (fn == null || file == null || sub == null || sub.isEmpty) {
            continue;
          }
          final base = _stripRomExtension(file, fn);
          subdirs[_esdeSubdirKey(fn, base)] = sub;
        }
      }
      _esdeMediaSubdirs = subdirs;
    } catch (e) {
      _log.e('FileProvider: failed to load external media configuration: $e');
      _esdeRoot = null;
      _esdeSystemMediaPaths = {};
      _manualSystemMediaPaths = {};
      _esdeMediaSubdirs = {};
    }
  }

  Future<void> refreshEsde() async {
    await _loadEsdeConfig();
    notifyListeners();
  }

  List<String> getEsdeMediaCandidates(
    String systemFolderName,
    String imageType,
    String romName, [
    List<String>? extensions,
  ]) {
    final liveManual = FortSystemPathService.cachedForSystem(
      systemFolderName,
    )?.mediaDirectory;
    final manualPath =
        liveManual ?? _manualSystemMediaPaths[systemFolderName.toLowerCase()];
    final systemMediaPath =
        manualPath ?? _esdeSystemMediaPaths[systemFolderName];
    if (systemMediaPath == null) return const [];

    final mapped = _esdeMediaCategories[imageType];
    if (mapped == null) return const [];
    final categories = manualPath == null
        ? mapped
        : <String>{imageType, ...mapped}.toList();

    final baseName = _stripRomExtension(romName, systemFolderName);
    final subdir =
        _esdeMediaSubdirs[_esdeSubdirKey(systemFolderName, baseName)];
    final subdirs = <String>[
      if (subdir != null && subdir.isNotEmpty) subdir,
      '',
    ];
    final extList = extensions ?? _esdeMediaExtensions;

    final candidates = <String>[];
    for (final category in categories) {
      for (final sub in subdirs) {
        for (final extension in extList) {
          candidates.add(
            path.joinAll([
              systemMediaPath,
              category,
              if (sub.isNotEmpty) sub,
              '$baseName.$extension',
            ]),
          );
        }
      }
    }
    return candidates;
  }

  List<String> getEsdeVideoCandidates(String systemFolderName, String romName) {
    return getEsdeMediaCandidates(
      systemFolderName,
      'videos',
      romName,
      _esdeVideoExtensions,
    );
  }

  void reset() {
    _userDataPath = null;
    _mediaPath = null;
    _documentsPath = null;
    _esdeRoot = null;
    _esdeSystemMediaPaths = {};
    _manualSystemMediaPaths = {};
    _esdeMediaSubdirs = {};
    _isInitialized = false;
    notifyListeners();
  }
}
