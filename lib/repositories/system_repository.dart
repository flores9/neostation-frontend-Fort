import 'dart:io';
import '../models/system_model.dart';
import '../data/datasources/sqlite_service.dart';
import '../services/fort_esde_library_service.dart';

/// Repository for handling system data (app_systems - read-only)
class SystemRepository {
  static Future<List<SystemModel>> getAllSystems() async {
    var systems = await SqliteService.getAllSystems();
    if (systems.isEmpty) {
      await SqliteService.loadAndSyncSystems();
      systems = await SqliteService.getAllSystems();
    }
    return systems;
  }

  static Future<SystemModel?> getSystemByFolderName(String folderName) async {
    try {
      final fort = await FortEsdeLibraryService.getPlatform(folderName);
      if (fort != null) {
        final profileId = fort['app_system_id']?.toString();
        if (profileId != null) {
          final profile = await getSystemById(profileId);
          if (profile != null) {
            final detected =
                await FortEsdeLibraryService.getDetectedPlatformSystems();
            for (final candidate in detected) {
              if (candidate.folderName.toLowerCase() ==
                  folderName.toLowerCase()) {
                return candidate;
              }
            }
            return profile.copyWith(
              folderName: fort['esde_system_name']?.toString() ?? folderName,
              realName: fort['display_name']?.toString() ?? folderName,
              folders: [folderName],
            );
          }
        }
      }
      return await SqliteService.getSystemByFolderName(folderName);
    } catch (e) {
      return null;
    }
  }

  static Future<SystemModel?> getSystemById(String id) async {
    final systems = await getAllSystems();
    try {
      return systems.firstWhere((s) => s.id == id);
    } catch (e) {
      return null;
    }
  }

  static Future<SystemModel> getCanonicalProfile(SystemModel system) async {
    final id = system.id;
    if (id == null ||
        !await FortEsdeLibraryService.isLibraryPlatform(system.folderName)) {
      return system;
    }
    return await getSystemById(id) ?? system;
  }

  static Future<List<SystemModel>> searchSystems(String query) async {
    final systems = await getAllSystems();
    final lowerQuery = query.toLowerCase();

    return systems
        .where(
          (s) =>
              s.realName.toLowerCase().contains(lowerQuery) ||
              s.folderName.toLowerCase().contains(lowerQuery),
        )
        .toList();
  }

  /// Get detected systems with ROM count.
  ///
  /// ES-DE concrete library identities replace the native canonical tile for
  /// their emulator profile. A stale Fort row whose name is itself the
  /// canonical NeoStation folder is also suppressed whenever a concrete sibling
  /// for that same profile exists. This makes old alias-driven databases safe to
  /// display even before their overlay rows are fully reconciled.
  static Future<List<SystemModel>> getDetectedSystems() async {
    final allSystems = await getAllSystems();
    final detected = await SqliteService.getUserDetectedSystems();

    final native = detected.where((d) {
      final isPresent = allSystems.any((s) => s.folderName == d.folderName);
      if (!isPresent) return false;

      if (d.folderName == 'android' && !Platform.isAndroid) {
        return false;
      }

      return true;
    }).toList();

    final rawFortPlatforms =
        await FortEsdeLibraryService.getDetectedPlatformSystems();
    if (rawFortPlatforms.isEmpty) return native;

    final canonicalFolderByProfile = <String, String>{
      for (final system in allSystems)
        if (system.id != null)
          system.id!: system.folderName.toLowerCase(),
    };
    final profileHasConcreteSibling = <String, bool>{};
    for (final platform in rawFortPlatforms) {
      final profileId = platform.id;
      if (profileId == null) continue;
      final canonical = canonicalFolderByProfile[profileId];
      if (canonical != null && platform.folderName.toLowerCase() != canonical) {
        profileHasConcreteSibling[profileId] = true;
      }
    }

    final fortPlatforms = rawFortPlatforms.where((platform) {
      final profileId = platform.id;
      if (profileId == null) return true;
      final canonical = canonicalFolderByProfile[profileId];
      if (canonical == null) return true;
      final isCanonicalAlias = platform.folderName.toLowerCase() == canonical;
      return !(isCanonicalAlias &&
          (profileHasConcreteSibling[profileId] ?? false));
    }).toList(growable: false);

    if (fortPlatforms.isEmpty) return native;

    final representedProfiles = fortPlatforms
        .map((platform) => platform.id)
        .whereType<String>()
        .toSet();
    final combined = <SystemModel>[
      ...native.where(
        (system) =>
            system.isVirtual ||
            system.folderName == 'all' ||
            system.folderName == 'favorites' ||
            !representedProfiles.contains(system.id),
      ),
      ...fortPlatforms,
    ];

    final seen = <String>{};
    return combined.where((system) {
      return seen.add(system.folderName.toLowerCase());
    }).toList();
  }

  static Future<bool> isSystemDetected(String folderName) async {
    final detectedSystems = await getDetectedSystems();
    return detectedSystems.any((s) => s.folderName == folderName);
  }

  static Future<int> getDetectedSystemCount() async {
    final detectedSystems = await getDetectedSystems();
    return detectedSystems.length;
  }

  static Future<void> setRecursiveScan(String systemId, bool value) =>
      SqliteService.setSystemRecursiveScan(systemId, value);

  static Future<void> setPreferFileName(String systemId, bool value) =>
      SqliteService.setSystemPreferFileName(systemId, value);

  static Future<void> setSubfolderView(String systemId, bool value) =>
      SqliteService.setSystemSubfolderView(systemId, value);

  static Future<void> setSubfolderViewForAll(bool value) =>
      SqliteService.setSubfolderViewForAllSystems(value);

  static Future<int> countSubfolderViewOverrides(bool globalValue) =>
      SqliteService.countSubfolderViewOverrides(globalValue);

  static Future<void> setHideExtension(String systemId, bool value) =>
      SqliteService.setSystemHideExtension(systemId, value);

  static Future<void> setHideParentheses(String systemId, bool value) =>
      SqliteService.setSystemHideParentheses(systemId, value);

  static Future<void> setHideBrackets(String systemId, bool value) =>
      SqliteService.setSystemHideBrackets(systemId, value);

  static Future<void> setCustomImages(
    String systemId, {
    String? backgroundPath,
    String? logoPath,
  }) => SqliteService.setSystemCustomImages(
    systemId,
    backgroundPath: backgroundPath,
    logoPath: logoPath,
  );

  static Future<void> addDetectedSystem(
    String systemId,
    String actualFolderName,
  ) => SqliteService.addDetectedSystem(systemId, actualFolderName);

  static Future<void> removeDetectedSystem(String systemId) =>
      SqliteService.removeDetectedSystem(systemId);

  static Future<void> updateDetectedSystems(List<String> folderNames) =>
      SqliteService.updateDetectedSystems(folderNames);

  static Future<Set<String>> getHiddenSystems() async {
    final native = await SqliteService.getHiddenSystems();
    final fort = await FortEsdeLibraryService.getHiddenPlatforms();
    return {...native, ...fort};
  }

  static Future<void> setSystemHidden(String folderName, bool isHidden) async {
    if (await FortEsdeLibraryService.isLibraryPlatform(folderName)) {
      await FortEsdeLibraryService.setPlatformHidden(folderName, isHidden);
      return;
    }
    await SqliteService.setSystemHidden(folderName, isHidden);
  }

  static Future<int> getRomCountForSystem(String systemId) =>
      SqliteService.getRomCountForSystem(systemId);

  static Future<Map<String, dynamic>> getSystemSettings(String systemId) =>
      SqliteService.getSystemSettings(systemId);

  static Future<Set<String>> getExtensionsForSystem(String systemId) =>
      SqliteService.getExtensionsForSystem(systemId);

  static Future<Set<String>> getAllValidExtensions() =>
      SqliteService.getAllValidExtensions();

  static Future<Map<String, Set<String>>> getSystemExtensionsMap() =>
      SqliteService.getSystemExtensionsMap();

  static Future<Map<String, int>> getSystemStats() async {
    final allSystems = await getAllSystems();
    final detectedSystems = await getDetectedSystems();

    int totalRoms = 0;

    for (final system in detectedSystems) {
      totalRoms += system.romCount;
    }

    return {
      'totalAvailable': allSystems.length,
      'totalDetected': detectedSystems.length,
      'totalRoms': totalRoms,
    };
  }
}
