import 'dart:io';

import '../models/system_model.dart';
import 'esde_config_resolver.dart';
import 'fort_system_path_service.dart';

/// One concrete ES-DE source that should be scanned as part of a NeoStation
/// emulation profile.
class FortEsdeScanSource {
  final String esdeSystemName;
  final String romDirectory;
  final String displayName;
  final String mediaDirectory;
  final String? gamelistFile;
  final String? theme;
  final List<String> platformTags;
  final bool manualRomDirectory;

  const FortEsdeScanSource({
    required this.esdeSystemName,
    required this.romDirectory,
    required this.displayName,
    required this.mediaDirectory,
    this.gamelistFile,
    this.theme,
    this.platformTags = const [],
    this.manualRomDirectory = false,
  });
}

/// Builds the Fort scan plan without changing NeoStation's emulator-profile
/// model.
///
/// NeoStation's `SystemModel.folders` is a compatibility/alias list. ES-DE may
/// use several of those names as independent library systems. This resolver
/// therefore returns *all* concrete ES-DE sources that belong to a canonical
/// NeoStation profile instead of choosing the first matching alias.
class FortEsdeScanPlanService {
  FortEsdeScanPlanService._();

  static Future<List<FortEsdeScanSource>> resolve(
    SystemModel system, {
    String? esdeRoot,
  }) async {
    final overrides = await FortSystemPathService.loadAll();
    final root = esdeRoot?.trim();
    EsdeResolvedConfig? resolved;
    if (root != null && root.isNotEmpty) {
      try {
        resolved = await EsdeConfigResolver.load(root);
      } catch (_) {
        resolved = null;
      }
    }

    final names = <String>{system.folderName, ...system.folders};
    final sources = <FortEsdeScanSource>[];
    final seen = <String>{};

    for (final rawName in names) {
      final name = rawName.trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      final manual = overrides[key];
      final definition = resolved?.systems[key];
      final auto = resolved?.forSystem(name);

      final manualRom = _clean(manual?.romDirectory);
      String? romDirectory = manualRom;
      if (romDirectory == null && resolved != null) {
        final explicit = resolved.customSystemRomPaths[key];
        if (explicit != null && explicit.isNotEmpty) {
          romDirectory = explicit;
        } else if (definition != null) {
          romDirectory = auto?.romDirectory;
        } else {
          // A global ROMDirectory can support systems not listed in the custom
          // XML. Only accept that fallback when the concrete folder exists;
          // otherwise every harmless NeoStation alias would become a missing
          // storage source and would block conservative orphan cleanup.
          final candidate = auto?.romDirectory;
          if (candidate != null && _directoryExists(candidate)) {
            romDirectory = candidate;
          }
        }
      }
      if (romDirectory == null || romDirectory.isEmpty) continue;

      final mediaDirectory =
          _clean(manual?.mediaDirectory) ??
          auto?.mediaDirectory ??
          romDirectory;
      final gamelistFile =
          _clean(manual?.gamelistFile) ??
          auto?.firstExistingGamelist ??
          (auto != null && auto.gamelistCandidates.isNotEmpty
              ? auto.gamelistCandidates.first
              : null);

      final identity = '$key\u0000${_normalize(romDirectory)}';
      if (!seen.add(identity)) continue;

      sources.add(
        FortEsdeScanSource(
          esdeSystemName: name,
          romDirectory: romDirectory,
          displayName: definition?.fullName ?? name,
          mediaDirectory: mediaDirectory,
          gamelistFile: gamelistFile,
          theme: definition?.theme,
          platformTags: definition?.platformTags ?? const [],
          manualRomDirectory: manualRom != null,
        ),
      );
    }

    return sources;
  }

  static bool _directoryExists(String candidate) {
    if (candidate.startsWith('content://')) return true;
    try {
      return Directory(candidate).existsSync();
    } catch (_) {
      return false;
    }
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String _normalize(String value) =>
      value.trim().replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
}
