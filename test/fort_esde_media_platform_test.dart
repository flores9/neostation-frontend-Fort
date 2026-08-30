import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/services/fort_esde_library_service.dart';

import 'database_test_helper.dart';

void main() {
  group('Fort ES-DE media platform routing', () {
    final helper = DatabaseTestHelper();
    late dynamic db;
    late FileProvider provider;

    setUp(() async {
      db = await helper.setUp();
      await db.execute(
        "INSERT INTO app_systems "
        "(id, real_name, folder_name, screenscraper_id) "
        "VALUES ('cpc', 'Amstrad CPC', 'cpc', 65)",
      );
      await db.execute(
        "INSERT INTO user_config (id, esde_folder_path) "
        "VALUES (1, '/storage/emulated/0/ES-DE')",
      );

      await FortEsdeLibraryService.upsertPlatform(
        esdeSystemName: 'amstradcpc',
        appSystemId: 'cpc',
        displayName: 'Amstrad CPC',
        romDirectory: '/storage/sd/ROMs/amstradcpc',
        mediaDirectory: '/storage/sd/ROMs/amstradcpc',
      );
      await FortEsdeLibraryService.upsertPlatform(
        esdeSystemName: 'gx4000',
        appSystemId: 'cpc',
        displayName: 'Amstrad GX4000',
        romDirectory: '/storage/sd/ROMs/gx4000',
        mediaDirectory: '/storage/sd/ROMs/gx4000',
      );

      provider = FileProvider();
      await provider.refreshEsde();
    });

    tearDown(() async {
      await helper.tearDown();
    });

    test('GX4000 candidates never probe Amstrad CPC media', () {
      final candidates = provider.getEsdeMediaCandidates(
        'gx4000',
        'box2d',
        'Shared Name.zip',
      );

      expect(candidates, isNotEmpty);
      expect(
        candidates.every((candidate) => candidate.contains('/gx4000/')),
        isTrue,
      );
      expect(
        candidates.any((candidate) => candidate.contains('/amstradcpc/')),
        isFalse,
      );
    });

    test('Amstrad CPC candidates never probe GX4000 media', () {
      final candidates = provider.getEsdeMediaCandidates(
        'amstradcpc',
        'box2d',
        'Shared Name.dsk',
      );

      expect(candidates, isNotEmpty);
      expect(
        candidates.every((candidate) => candidate.contains('/amstradcpc/')),
        isTrue,
      );
      expect(
        candidates.any((candidate) => candidate.contains('/gx4000/')),
        isFalse,
      );
    });
  });
}
