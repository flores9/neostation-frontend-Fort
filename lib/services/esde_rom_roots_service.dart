import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../providers/sqlite_config_provider.dart';
import 'logger_service.dart';
import 'permission_service.dart';
import 'user_data_location_service.dart';

/// Result of synchronising NeoStation's configured ROM roots with ES-DE.
class EsdeRomRootSyncResult {
  final List<String> discoveredRoots;
  final List<String> addedRoots;
  final List<String> inaccessibleRoots;
  final List<String> skippedForCapacity;

  const EsdeRomRootSyncResult({
    this.discoveredRoots = const [],
    this.addedRoots = const [],
    this.inaccessibleRoots = const [],
    this.skippedForCapacity = const [],
  });
}

/// Discovers the storage roots used by ES-DE and keeps NeoStation's scanner in
/// step with them.
///
/// ES-DE's normal library root comes from `settings/es_settings.xml` as
/// `ROMDirectory`. Custom system definitions may override individual systems
/// with absolute `<path>` values in `custom_systems/es_systems.xml`; their
/// parent directory is therefore an additional ROM root. This is the common
/// Android handheld layout where most systems live on SD but one or more live
/// in internal storage.
class EsdeRomRootsService {
  EsdeRomRootsService._();

  static final _log = LoggerService.instance;

  /// Returns normalized ROM roots in deterministic order.
  ///
  /// The configured `ROMDirectory` is first, followed by extra roots inferred
  /// from system `<path>` entries. `%ROMPATH%`, `%ESPATH%` and `~` are expanded
  /// using the same semantics ES-DE uses for its settings paths.
  static List<String> discoverRomRoots(String esdeRoot) {
    final roots = <String>[];
    final romDirectory = _readEsdeSetting(esdeRoot, 'ROMDirectory');
    final expandedRomDirectory = romDirectory == null
        ? null
        : _expandPath(
            romDirectory,
            esdeRoot: esdeRoot,
            romDirectory: null,
          );

    if (expandedRomDirectory != null && expandedRomDirectory.isNotEmpty) {
      _addUnique(roots, expandedRomDirectory);
    }

    for (final systemsFile in _systemConfigCandidates(esdeRoot)) {
      if (!systemsFile.existsSync()) continue;

      XmlDocumentFragment document;
      try {
        document = XmlDocumentFragment.parse(
          utf8.decode(systemsFile.readAsBytesSync(), allowMalformed: true),
        );
      } catch (e) {
        _log.w('ES-DE ROM roots: cannot parse ${systemsFile.path}: $e');
        continue;
      }

      for (final system in document.findAllElements('system')) {
        final pathNode = system.getElement('path');
        final raw = pathNode?.innerText.trim();
        if (raw == null || raw.isEmpty) continue;

        final expanded = _expandPath(
          raw,
          esdeRoot: esdeRoot,
          romDirectory: expandedRomDirectory,
        );
        if (expanded == null || expanded.isEmpty) continue;

        // A system path points at its platform directory. NeoStation wants the
        // root that contains platform directories, so register the parent.
        final parent = path.dirname(expanded);
        if (parent.isNotEmpty && parent != '.') _addUnique(roots, parent);
      }
    }

    return roots;
  }

  /// Adds every newly discovered root that NeoStation can access and performs
  /// one scan after all additions.
  ///
  /// Existing SAF roots are compared through their resolved `/storage/...`
  /// path, so the same SD card root is not added twice under two spellings.
  /// The scan intentionally happens before ES-DE metadata import: the importer
  /// can then match metadata for ROMs from newly discovered roots in the same
  /// user action instead of requiring a second manual import.
  static Future<EsdeRomRootSyncResult> syncAndScan(
    SqliteConfigProvider provider,
    String esdeRoot,
  ) async {
    final discovered = discoverRomRoots(esdeRoot);
    final added = <String>[];
    final inaccessible = <String>[];
    final capacity = <String>[];

    for (final root in discovered) {
      if (_isAlreadyConfigured(provider.config.romFolders, root)) continue;

      if (provider.config.romFolders.length >= 5) {
        capacity.add(root);
        continue;
      }

      if (!Directory(root).existsSync()) {
        inaccessible.add(root);
        continue;
      }

      if (Platform.isAndroid) {
        final canAccess = await PermissionService.canAccessDirectory(root);
        if (!canAccess) {
          inaccessible.add(root);
          continue;
        }
      }

      await provider.addRomFolder(root, scan: false);
      if (_isAlreadyConfigured(provider.config.romFolders, root)) {
        added.add(root);
      }
    }

    // Always scan immediately before an ES-DE import when there is a library
    // configured. This keeps metadata matching correct even when no new root
    // was added but ROM contents changed since the previous import.
    if (provider.config.romFolders.isNotEmpty) {
      await provider.scanSystems();
    }

    if (added.isNotEmpty) {
      _log.i('ES-DE ROM roots: auto-added ${added.join(', ')}');
    }
    if (inaccessible.isNotEmpty) {
      _log.w(
        'ES-DE ROM roots: require storage access or are unavailable: '
        '${inaccessible.join(', ')}',
      );
    }

    return EsdeRomRootSyncResult(
      discoveredRoots: discovered,
      addedRoots: added,
      inaccessibleRoots: inaccessible,
      skippedForCapacity: capacity,
    );
  }

  static List<File> _systemConfigCandidates(String esdeRoot) => [
    File(path.join(esdeRoot, 'custom_systems', 'es_systems.xml')),
    // Kept as a fallback for portable/custom layouts that place the file at
    // the selected ES-DE root itself.
    File(path.join(esdeRoot, 'es_systems.xml')),
  ];

  static String? _readEsdeSetting(String esdeRoot, String settingName) {
    final settings = File(path.join(esdeRoot, 'settings', 'es_settings.xml'));
    if (!settings.existsSync()) return null;

    try {
      final doc = XmlDocumentFragment.parse(
        utf8.decode(settings.readAsBytesSync(), allowMalformed: true),
      );
      for (final element in doc.findAllElements('string')) {
        if (element.getAttribute('name') == settingName) {
          final value = element.getAttribute('value')?.trim();
          return value == null || value.isEmpty ? null : value;
        }
      }
    } catch (e) {
      _log.w('ES-DE ROM roots: failed reading ${settings.path}: $e');
    }
    return null;
  }

  static String? _expandPath(
    String raw, {
    required String esdeRoot,
    required String? romDirectory,
  }) {
    var value = raw.trim().replaceAll('\\', '/');
    if (value.isEmpty) return null;

    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      if (value == '~') {
        value = home;
      } else if (value.startsWith('~/')) {
        value = path.join(home, value.substring(2));
      }
    }

    if (value.contains('%ROMPATH%')) {
      if (romDirectory == null || romDirectory.isEmpty) return null;
      value = value.replaceAll('%ROMPATH%', romDirectory);
    }

    if (value.contains('%ESPATH%')) {
      // The selected ES-DE data directory is the most useful answer on Android
      // and portable installs; it mirrors the importer's path expansion.
      value = value.replaceAll('%ESPATH%', esdeRoot);
    }

    // A relative system path is meaningful only relative to ROMDirectory.
    if (!path.isAbsolute(value)) {
      if (romDirectory == null || romDirectory.isEmpty) return null;
      value = path.join(romDirectory, value);
    }

    return _normalize(value);
  }

  static bool _isAlreadyConfigured(List<String> configured, String candidate) {
    final wanted = _normalize(candidate).toLowerCase();
    for (final value in configured) {
      final real = value.startsWith('content://')
          ? UserDataLocationService.safUriToRealPath(value)
          : value;
      if (real == null || real.isEmpty) continue;
      if (_normalize(real).toLowerCase() == wanted) return true;
    }
    return false;
  }

  static String _normalize(String value) {
    var normalized = path.normalize(value.replaceAll('\\', '/'));
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static void _addUnique(List<String> values, String candidate) {
    final normalized = _normalize(candidate);
    if (normalized.isEmpty) return;
    if (values.any((v) => v.toLowerCase() == normalized.toLowerCase())) return;
    values.add(normalized);
  }
}
