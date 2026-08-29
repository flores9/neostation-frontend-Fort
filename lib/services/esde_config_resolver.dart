import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

/// Snapshot of the ES-DE settings that affect external library routing.
class EsdePathSettings {
  final String? romDirectory;
  final String? mediaDirectory;
  final bool legacyGamelistFileLocation;

  const EsdePathSettings({
    this.romDirectory,
    this.mediaDirectory,
    this.legacyGamelistFileLocation = false,
  });
}

/// Effective ES-DE paths for one system.
///
/// Paths in this model are read-only inputs. NeoStation must never write to an
/// ES-DE ROM, media or gamelist path through this resolver.
class EsdeSystemPaths {
  final String systemName;
  final String? romDirectory;
  final String mediaDirectory;
  final List<String> gamelistCandidates;

  const EsdeSystemPaths({
    required this.systemName,
    required this.romDirectory,
    required this.mediaDirectory,
    required this.gamelistCandidates,
  });

  /// Returns the first gamelist candidate that currently exists on disk.
  String? get firstExistingGamelist {
    for (final candidate in gamelistCandidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }
}

/// Parsed ES-DE configuration used by the importer and per-system overrides.
class EsdeResolvedConfig {
  final String esdeRoot;
  final EsdePathSettings settings;
  final Map<String, String> customSystemRomPaths;

  const EsdeResolvedConfig({
    required this.esdeRoot,
    required this.settings,
    required this.customSystemRomPaths,
  });

  String get mediaRoot =>
      settings.mediaDirectory ?? path.join(esdeRoot, 'downloaded_media');

  /// Resolves the effective ES-DE paths for [systemName].
  ///
  /// A custom system path wins over the global ROMDirectory. MediaDirectory is
  /// independent from the ROM location, exactly as it is in ES-DE.
  EsdeSystemPaths forSystem(String systemName) {
    final normalizedName = systemName.trim();
    final key = normalizedName.toLowerCase();
    final customRomPath = customSystemRomPaths[key];
    final romPath =
        customRomPath ??
        (settings.romDirectory == null
            ? null
            : path.join(settings.romDirectory!, normalizedName));

    final standardGamelist = path.join(
      esdeRoot,
      'gamelists',
      normalizedName,
      'gamelist.xml',
    );
    final romGamelist = romPath == null
        ? null
        : path.join(romPath, 'gamelist.xml');

    final candidates = <String>[];
    // When ES-DE legacy gamelist mode is enabled the ROM-local file is the
    // intentional location and must be preferred. Otherwise the modern
    // central gamelist is authoritative, but Fort still probes the ROM-local
    // location as a defensive fallback for migrated/custom libraries.
    if (settings.legacyGamelistFileLocation && romGamelist != null) {
      candidates.add(romGamelist);
    }
    candidates.add(standardGamelist);
    if (!settings.legacyGamelistFileLocation && romGamelist != null) {
      candidates.add(romGamelist);
    }

    return EsdeSystemPaths(
      systemName: normalizedName,
      romDirectory: romPath,
      mediaDirectory: path.join(mediaRoot, normalizedName),
      gamelistCandidates: List.unmodifiable(candidates),
    );
  }
}

/// Reads the ES-DE configuration files that define ROM, media and gamelist
/// locations.
///
/// ES-DE's `es_settings.xml` is intentionally parsed as an XML fragment rather
/// than a document: it contains multiple top-level setting elements. The
/// resolver also reads `custom_systems/es_systems.xml`, expanding `%ROMPATH%`
/// against the configured global ROMDirectory while preserving absolute paths
/// used to place individual systems on another storage volume.
class EsdeConfigResolver {
  const EsdeConfigResolver._();

  static Future<EsdeResolvedConfig> load(String esdeRoot) async {
    final normalizedRoot = path.normalize(esdeRoot);
    final settingsFile = File(
      path.join(normalizedRoot, 'settings', 'es_settings.xml'),
    );
    final customSystemsFile = File(
      path.join(normalizedRoot, 'custom_systems', 'es_systems.xml'),
    );

    final settings = settingsFile.existsSync()
        ? parseSettings(await settingsFile.readAsString())
        : const EsdePathSettings();

    final customPaths = customSystemsFile.existsSync()
        ? parseCustomSystemPaths(
            await customSystemsFile.readAsString(),
            romDirectory: settings.romDirectory,
          )
        : const <String, String>{};

    return EsdeResolvedConfig(
      esdeRoot: normalizedRoot,
      settings: settings,
      customSystemRomPaths: Map.unmodifiable(customPaths),
    );
  }

  /// Parses the relevant values from ES-DE's multi-root settings fragment.
  static EsdePathSettings parseSettings(String contents) {
    final fragment = XmlDocumentFragment.parse(contents);
    String? romDirectory;
    String? mediaDirectory;
    var legacyGamelistFileLocation = false;

    for (final element in fragment.descendants.whereType<XmlElement>()) {
      final settingName = element.getAttribute('name');
      if (settingName == null) continue;
      final rawValue = element.getAttribute('value')?.trim();

      switch (settingName) {
        case 'ROMDirectory':
          romDirectory = _nonEmptyNormalized(rawValue);
          break;
        case 'MediaDirectory':
          mediaDirectory = _nonEmptyNormalized(rawValue);
          break;
        case 'LegacyGamelistFileLocation':
          legacyGamelistFileLocation = rawValue?.toLowerCase() == 'true';
          break;
      }
    }

    return EsdePathSettings(
      romDirectory: romDirectory,
      mediaDirectory: mediaDirectory,
      legacyGamelistFileLocation: legacyGamelistFileLocation,
    );
  }

  /// Parses custom ES-DE system ROM paths keyed case-insensitively by system.
  static Map<String, String> parseCustomSystemPaths(
    String contents, {
    String? romDirectory,
  }) {
    final fragment = XmlDocumentFragment.parse(contents);
    final result = <String, String>{};

    for (final system in fragment.findAllElements('system')) {
      final name = system.getElement('name')?.innerText.trim();
      final rawPath = system.getElement('path')?.innerText.trim();
      if (name == null || name.isEmpty || rawPath == null || rawPath.isEmpty) {
        continue;
      }

      final resolved = _resolveSystemPath(rawPath, romDirectory: romDirectory);
      if (resolved != null) result[name.toLowerCase()] = resolved;
    }

    return result;
  }

  static String? _resolveSystemPath(
    String rawPath, {
    required String? romDirectory,
  }) {
    var value = rawPath.trim();
    if (value.isEmpty) return null;

    if (value.contains('%ROMPATH%')) {
      if (romDirectory == null || romDirectory.isEmpty) {
        // Never guess the meaning of %ROMPATH% when ES-DE did not persist its
        // ROMDirectory. A guessed path can point NeoStation at the wrong volume.
        return null;
      }
      value = value.replaceAll('%ROMPATH%', romDirectory);
    }

    return _nonEmptyNormalized(value);
  }

  static String? _nonEmptyNormalized(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return path.normalize(trimmed);
  }
}
