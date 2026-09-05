import 'package:path/path.dart' as path;

import '../models/system_model.dart';

/// Portable Android ROM-path helpers used by the Fort ES-DE launcher overlay.
///
/// NeoStation normally keeps Android Storage Access Framework paths as
/// `content://` URIs. MAME4droid's CLI, however, expects real filesystem paths
/// inside its `cli_params` string. ExternalStorageProvider document URIs are
/// deterministic, so they can be decoded without platform I/O:
///
/// * `primary:ROMs/cdi/game.chd` -> `/storage/emulated/0/ROMs/cdi/game.chd`
/// * `14F5-471E:ROMs/cpc/game.dsk` -> `/storage/14F5-471E/ROMs/cpc/game.dsk`
///
/// Other document providers are intentionally left unresolved; they may not
/// have a real filesystem path at all.
class FortAndroidRomPath {
  FortAndroidRomPath._();

  static const String _externalStorageAuthority =
      'com.android.externalstorage.documents';

  static String? externalStorageRealPath(String value) {
    if (!value.startsWith('content://')) return null;

    final uri = Uri.tryParse(value);
    if (uri == null || uri.authority != _externalStorageAuthority) return null;

    const marker = '/document/';
    final markerIndex = value.indexOf(marker);
    if (markerIndex < 0) return null;

    var documentId = value.substring(markerIndex + marker.length);
    try {
      documentId = Uri.decodeComponent(documentId);
    } catch (_) {
      return null;
    }

    final colon = documentId.indexOf(':');
    if (colon <= 0 || colon == documentId.length - 1) return null;

    final volume = documentId.substring(0, colon);
    final relative = documentId.substring(colon + 1).replaceAll('\\', '/');
    if (relative.isEmpty) return null;

    if (volume.toLowerCase() == 'primary') {
      return path.posix.normalize('/storage/emulated/0/$relative');
    }
    return path.posix.normalize('/storage/$volume/$relative');
  }

  static String rawPath(String romPath) {
    final external = externalStorageRealPath(romPath);
    if (external != null) return external;
    if (romPath.startsWith('file://')) {
      return Uri.tryParse(romPath)?.toFilePath() ?? romPath;
    }
    return romPath;
  }

  static String fileDirectory(String romPath) =>
      path.posix.dirname(rawPath(romPath).replaceAll('\\', '/'));

  static String basenameWithoutExtension(String filename) =>
      path.posix.basenameWithoutExtension(filename.replaceAll('\\', '/'));

  static String romRoot(String romPath, SystemModel system) {
    final resolved = rawPath(romPath).replaceAll('\\', '/');
    final segments = path.posix.split(resolved);
    if (segments.isEmpty) return path.posix.dirname(resolved);

    final aliases = <String>{
      system.folderName.toLowerCase(),
      ...system.folders.map((folder) => folder.toLowerCase()),
    }..removeWhere((value) => value.isEmpty);

    for (var i = segments.length - 2; i >= 0; i--) {
      if (!aliases.contains(segments[i].toLowerCase())) continue;
      if (i == 0) return '/';
      return path.posix.joinAll(segments.sublist(0, i));
    }

    final gameDir = path.posix.dirname(resolved);
    return path.posix.dirname(gameDir);
  }

  /// Ensures MAME4droid searches the common ROM root as well as the platform
  /// directory. This supports loose BIOS files stored directly alongside ROMs.
  static String ensureMameRomRoot(
    String cliParams,
    String romPath,
    SystemModel system,
  ) {
    final match = RegExp(r'''-rompath\s+(['"])(.*?)\1''').firstMatch(cliParams);
    if (match == null) return cliParams;

    final quote = match.group(1)!;
    final existing = match.group(2)!;
    final root = romRoot(romPath, system);

    final paths = <String>[];
    for (final value in [...existing.split(';'), root]) {
      final normalized = path.posix.normalize(value.trim().replaceAll('\\', '/'));
      if (normalized.isEmpty || normalized == '.') continue;
      if (paths.any((item) => item.toLowerCase() == normalized.toLowerCase())) {
        continue;
      }
      paths.add(normalized);
    }

    if (paths.isEmpty) return cliParams;
    final replacement = '-rompath $quote${paths.join(';')}$quote';
    return cliParams.replaceRange(match.start, match.end, replacement);
  }
}
