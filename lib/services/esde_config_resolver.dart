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

/// One system declared by ES-DE.
///
/// This is deliberately a *library platform* definition, not an emulator
/// profile. Several ES-DE systems can legitimately map to the same NeoStation
/// emulator profile (for example `amstradcpc` and `gx4000` -> `cpc`) while
/// remaining distinct platforms with their own ROMs, gamelist and media.
class EsdeSystemDefinition {
  final String name;
  final String fullName;
  final String? romDirectory;
  final String? theme;
  final List<String> platformTags;
  final List<String> extensions;

  const EsdeSystemDefinition({
    required this.name,
    required this.fullName,
    this.romDirectory,
    this.theme,
    this.platformTags = const [],
    this.extensions = const [],
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

  /// ES-DE systems keyed by their lower-case `<name>`.
  final Map<String, EsdeSystemDefinition> systems;

  const EsdeResolvedConfig({
    required this.esdeRoot,
    required this.settings,
    required this.customSystemRomPaths,
    this.systems = const {},
  });

  String get mediaRoot =>
      settings.mediaDirectory ?? path.posix.join(esdeRoot, 'downloaded_media');

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
            : path.posix.join(settings.romDirectory!, normalizedName));

    final standardGamelist = path.posix.join(
      esdeRoot,
      'gamelists',
      normalizedName,
      'gamelist.xml',
    );
    final romGamelist = romPath == null
        ? null
        : path.posix.join(romPath, 'gamelist.xml');

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
      mediaDirectory: path.posix.join(mediaRoot, normalizedName),
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
    final normalizedRoot = path.posix.normalize(esdeRoot);
    final settingsFile = File(
      path.posix.join(normalizedRoot, 'settings', 'es_settings.xml'),
    );
    final customSystemsFile = File(
      path.posix.join(normalizedRoot, 'custom_systems', 'es_systems.xml'),
    );

    final settings = settingsFile.existsSync()
        ? parseSettings(await settingsFile.readAsString())
        : const EsdePathSettings();

    final systems = customSystemsFile.existsSync()
        ? parseCustomSystems(
            await customSystemsFile.readAsString(),
            romDirectory: settings.romDirectory,
          )
        : const <String, EsdeSystemDefinition>{};
    final customPaths = <String, String>{
      for (final entry in systems.entries)
        if (entry.value.romDirectory != null)
          entry.key: entry.value.romDirectory!,
    };

    return EsdeResolvedConfig(
      esdeRoot: normalizedRoot,
      settings: settings,
      customSystemRomPaths: Map.unmodifiable(customPaths),
      systems: Map.unmodifiable(systems),
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

  /// Parses complete custom ES-DE system definitions keyed case-insensitively
  /// by `<name>`.
  ///
  /// Keeping `fullname`, `theme` and the original ES-DE identity is important:
  /// NeoStation's `folders` list is an emulator-profile compatibility list and
  /// must not be used to collapse several ES-DE platforms into one library.
  static Map<String, EsdeSystemDefinition> parseCustomSystems(
    String contents, {
    String? romDirectory,
  }) {
    final fragment = XmlDocumentFragment.parse(contents);
    final result = <String, EsdeSystemDefinition>{};

    for (final system in fragment.findAllElements('system')) {
      final name = system.getElement('name')?.innerText.trim();
      if (name == null || name.isEmpty) continue;

      final rawPath = system.getElement('path')?.innerText.trim();
      final resolvedPath = rawPath == null || rawPath.isEmpty
          ? null
          : _resolveSystemPath(rawPath, romDirectory: romDirectory);
      final fullNameRaw = system.getElement('fullname')?.innerText.trim();
      final themeRaw = system.getElement('theme')?.innerText.trim();
      final platformRaw = system.getElement('platform')?.innerText.trim();
      final extensionRaw = system.getElement('extension')?.innerText.trim();

      result[name.toLowerCase()] = EsdeSystemDefinition(
        name: name,
        fullName: fullNameRaw == null || fullNameRaw.isEmpty
            ? name
            : fullNameRaw,
        romDirectory: resolvedPath,
        theme: themeRaw == null || themeRaw.isEmpty ? null : themeRaw,
        platformTags: _splitTokens(platformRaw, commaAware: true),
        extensions: _splitTokens(extensionRaw),
      );
    }

    return result;
  }

  /// Backwards-compatible path-only view used by existing Fort code.
  static Map<String, String> parseCustomSystemPaths(
    String contents, {
    String? romDirectory,
  }) {
    final systems = parseCustomSystems(contents, romDirectory: romDirectory);
    return <String, String>{
      for (final entry in systems.entries)
        if (entry.value.romDirectory != null)
          entry.key: entry.value.romDirectory!,
    };
  }

  static List<String> _splitTokens(String? value, {bool commaAware = false}) {
    if (value == null || value.trim().isEmpty) return const [];
    final normalized = commaAware ? value.replaceAll(',', ' ') : value;
    return normalized
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
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
    return path.posix.normalize(trimmed.replaceAll('\\', '/'));
  }
}
