import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/system_model.dart';
import 'esde_config_resolver.dart';
import 'fort_esde_platform_reconciler.dart';
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

class _FortEsdeCandidate {
  final String name;
  final int evidence;

  const _FortEsdeCandidate(this.name, this.evidence);
}

/// Builds the Fort scan plan without changing NeoStation's emulator-profile
/// model.
///
/// ES-DE owns library identity; NeoStation owns emulation profiles. The aliases
/// in `SystemModel.folders` are therefore only a compatibility map used to
/// decide which NeoStation profile can launch an ES-DE system. An alias is not,
/// by itself, evidence that a library platform exists.
class FortEsdeScanPlanService {
  FortEsdeScanPlanService._();

  static const int _romFolderEvidence = 1;
  static const int _mediaEvidence = 2;
  static const int _gamelistEvidence = 3;
  static const int _explicitEsdeEvidence = 4;
  static const int _manualEvidence = 5;

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

    final aliases = <String, String>{};
    for (final rawName in <String>{system.folderName, ...system.folders}) {
      final name = rawName.trim();
      if (name.isEmpty) continue;
      aliases[name.toLowerCase()] = name;
    }

    final candidates = <String, _FortEsdeCandidate>{};
    void addCandidate(String rawName, int evidence) {
      final name = rawName.trim();
      if (name.isEmpty) return;
      final key = name.toLowerCase();
      if (!aliases.containsKey(key)) return;
      final current = candidates[key];
      if (current == null || evidence > current.evidence) {
        candidates[key] = _FortEsdeCandidate(name, evidence);
      }
    }

    // A manual Fort override is an explicit user decision and is therefore the
    // strongest possible evidence for a concrete library identity.
    for (final key in overrides.keys) {
      if (aliases.containsKey(key)) {
        addCandidate(key, _manualEvidence);
      }
    }

    if (resolved != null) {
      // Custom ES-DE definitions are explicit declarations from ES-DE itself.
      for (final definition in resolved.systems.values) {
        addCandidate(definition.name, _explicitEsdeEvidence);
      }

      // Modern ES-DE gamelist folders preserve the concrete system name even
      // when the ROMs live on another volume.
      final central = Directory(path.join(resolved.esdeRoot, 'gamelists'));
      if (_canList(central.path)) {
        try {
          for (final dir in central.listSync().whereType<Directory>()) {
            if (File(path.join(dir.path, 'gamelist.xml')).existsSync()) {
              addCandidate(path.basename(dir.path), _gamelistEvidence);
            }
          }
        } catch (_) {
          // Storage can disappear between exists/list; weaker evidence below
          // may still keep a previously valid source discoverable.
        }
      }

      // ES-DE media is also namespaced by the concrete system identity.
      final mediaRoot = Directory(resolved.mediaRoot);
      if (_canList(mediaRoot.path)) {
        try {
          for (final dir in mediaRoot.listSync().whereType<Directory>()) {
            addCandidate(path.basename(dir.path), _mediaEvidence);
          }
        } catch (_) {
          // Same removable-storage race as the gamelist enumeration above.
        }
      }

      // A real ROM directory is useful fallback evidence for systems that have
      // no gamelist/media yet. Crucially, content:// is NOT accepted blindly:
      // Directory cannot verify a SAF URI and the old `return true` behaviour
      // promoted every harmless NeoStation alias into a visible platform.
      for (final alias in aliases.values) {
        final key = alias.toLowerCase();
        final explicit = resolved.customSystemRomPaths[key];
        if (explicit != null && explicit.isNotEmpty) {
          addCandidate(alias, _explicitEsdeEvidence);
          continue;
        }
        final romDirectory = resolved.forSystem(alias).romDirectory;
        if (romDirectory != null && _verifiedDirectoryExists(romDirectory)) {
          addCandidate(alias, _romFolderEvidence);
        }
      }
    }

    // The canonical NeoStation folder is commonly just an emulator-profile
    // name (`cpc`, `genesis`, ...). If ES-DE gives us stronger evidence for a
    // different identity (`amstradcpc`, `megadrive`, ...), do not expose the
    // weak canonical fallback as a second library platform.
    final canonicalKey = system.folderName.trim().toLowerCase();
    final canonical = candidates[canonicalKey];
    final hasStrongerSibling = candidates.entries.any(
      (entry) =>
          entry.key != canonicalKey && entry.value.evidence > _romFolderEvidence,
    );
    if (canonical != null &&
        canonical.evidence == _romFolderEvidence &&
        hasStrongerSibling) {
      candidates.remove(canonicalKey);
    }

    final orderedCandidates = candidates.values.toList()
      ..sort((a, b) {
        final evidence = b.evidence.compareTo(a.evidence);
        if (evidence != 0) return evidence;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final sources = <FortEsdeScanSource>[];
    final rootOwners = <String, _FortEsdeCandidate>{};

    for (final candidate in orderedCandidates) {
      final name = candidate.name;
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
        } else if (definition != null || candidate.evidence > _romFolderEvidence) {
          // Strong ES-DE identity evidence is enough to trust the configured
          // ROMDirectory even when dart:io cannot probe that volume directly.
          romDirectory = auto?.romDirectory;
        } else {
          final fallback = auto?.romDirectory;
          if (fallback != null && _verifiedDirectoryExists(fallback)) {
            romDirectory = fallback;
          }
        }
      }
      if (romDirectory == null || romDirectory.isEmpty) continue;

      final normalizedRoot = _normalize(romDirectory);
      final owner = rootOwners[normalizedRoot];
      if (owner != null &&
          owner.name.toLowerCase() != key &&
          (owner.evidence <= _romFolderEvidence ||
              candidate.evidence <= _romFolderEvidence)) {
        // Same physical source plus one weak alias: keep the stronger ES-DE
        // identity. Two explicit/strong ES-DE systems are allowed to share a
        // root because their extension filters may intentionally differ.
        continue;
      }
      rootOwners.putIfAbsent(normalizedRoot, () => candidate);

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

    // Clean rows created by the old alias-driven model only when we have a
    // concrete replacement plan. The reconciliation changes provenance only;
    // it never deletes user_roms, favourites, playtime or metadata.
    final profileId = system.id;
    if (profileId != null && profileId.isNotEmpty && sources.isNotEmpty) {
      await FortEsdePlatformReconciler.reconcileProfile(
        appSystemId: profileId,
        activeSources: {
          for (final source in sources)
            source.esdeSystemName: source.romDirectory,
        },
      );
    }

    return sources;
  }

  static bool _verifiedDirectoryExists(String candidate) {
    final value = candidate.trim();
    if (value.isEmpty || value.startsWith('content://')) return false;
    try {
      return Directory(value).existsSync();
    } catch (_) {
      return false;
    }
  }

  static bool _canList(String candidate) {
    final value = candidate.trim();
    if (value.isEmpty || value.startsWith('content://')) return false;
    try {
      return Directory(value).existsSync();
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
