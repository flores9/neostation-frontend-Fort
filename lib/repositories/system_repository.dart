import 'dart:io';
import '../models/system_model.dart';
import '../data/datasources/sqlite_service.dart';
import '../services/fort_esde_library_service.dart';

/// Repository for handling system data (app_systems - read-only)
class SystemRepository {
  /// Get all available systems from the database
  static Future<List<SystemModel>> getAllSystems() async {
    // If the DB is empty, force sync during app startup if necessary
    var systems = await SqliteService.getAllSystems();
    if (systems.isEmpty) {
      await SqliteService.loadAndSyncSystems();
      systems = await SqliteService.getAllSystems();
    }
    return systems;
  }

  /// Get a system by its folder_name.
  ///
  /// Fort ES-DE library platforms are checked first because their folder name
  /// intentionally does not exist as a canonical `app_systems.folder_name`.
  /// They still carry the canonical profile id, so emulator configuration and
  /// launch resolution remain entirely upstream-owned.
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

  /// Get a system by its ID
  static Future<SystemModel?> getSystemById(String id) async {
    final systems = await getAllSystems();
    try {
      return systems.firstWhere((s) => s.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Search systems by name (real_name or folder_name)
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

  /// Get detected systems with rom count.
  ///
  /// When Fort has source provenance for a canonical profile, replace that one
  /// collapsed tile with its concrete ES-DE platforms. Example: the upstream
  /// `cpc` tile becomes `amstradcpc` and `gx4000`, both retaining id `cpc` for
  /// emulator selection.
  static Future<List<SystemModel>> getDetectedSystems() async {
    final allSystems = await getAllSystems();
    final detected = await SqliteService.getUserDetectedSystems();

    final native = detected.where((d) {
      final isPresent = allSystems.any((s) => s.folderName == d.folderName);
      if (!isPresent) return false;

      // Filter out Android if not on Android platform
      if (d.folderName == 'android' && !Platform.isAndroid) {
        return false;
      }

      return true;
    }).toList();

    final fortPlatforms =
        await FortEsdeLibraryService.getDetectedPlatformSystems();
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

  /// Check if a system is detected
  static Future<bool> isSystemDetected(String folderName) async {
    final detectedSystems = await getDetectedSystems();
    return detectedSystems.any((s) => s.folderName == folderName);
  }

  /// Get total detected systems count
  static Future<int> getDetectedSystemCount() async {
    final detectedSystems = await getDetectedSystems();
    return detectedSystems.length;
  }

  // ── System display/scan settings (write) ──────────────────────────────────

  static Future<void> setRecursiveScan(String systemId, bool value) =>
      SqliteService.setSystemRecursiveScan(systemId, value);

  static Future<void> setPreferFileName(String systemId, bool value) =>
      SqliteService.setSystemPreferFileName(systemId, value);

  static Future<void> setSubfolderView(String systemId, bool value) =>
      SqliteService.setSystemSubfolderView(systemId, value);

  /// Applies "Show Subfolders" to every system at once (the global toggle in
  /// Settings > General).
  static Future<void> setSubfolderViewForAll(bool value) =>
      SqliteService.setSubfolderViewForAllSystems(value);

  /// How many systems carry a "Show Subfolders" setting of their own — one that
  /// differs from [globalValue], the last global choice — and would therefore
  /// be overwritten by the next global stamp.
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

  // ── System detection (write) ────────────────────────────────────────────

  static Future<void> addDetectedSystem(
    String systemId,
    String actualFolderName,
  ) => SqliteService.addDetectedSystem(systemId, actualFolderName);

  static Future<void> removeDetectedSystem(String systemId) =>
      SqliteService.removeDetectedSystem(systemId);

  static Future<void> updateDetectedSystems(List<String> folderNames) =>
      SqliteService.updateDetectedSystems(folderNames);

  // ── System visibility ─────────────────────────────────────────────────────

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

  // ── ROM counts ────────────────────────────────────────────────────────────

  static Future<int> getRomCountForSystem(String systemId) =>
      SqliteService.getRomCountForSystem(systemId);

  // ── System settings ───────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getSystemSettings(String systemId) =>
      SqliteService.getSystemSettings(systemId);

  static Future<Set<String>> getExtensionsForSystem(String systemId) =>
      SqliteService.getExtensionsForSystem(systemId);

  // ── System extensions ─────────────────────────────────────────────────────

  static Future<Set<String>> getAllValidExtensions() =>
      SqliteService.getAllValidExtensions();

  static Future<Map<String, Set<String>>> getSystemExtensionsMap() =>
      SqliteService.getSystemExtensionsMap();

  // ── System statistics ──────────────────────────────────────────────────────

  /// Get System Stats
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
