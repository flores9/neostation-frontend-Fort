import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/fort_esde_library_service.dart';

import 'database_test_helper.dart';

void main() {
  group('FortEsdeLibraryService', () {
    final helper = DatabaseTestHelper();
    late dynamic db;

    setUp(() async {
      db = await helper.setUp();
      await db.execute(
        "INSERT INTO app_systems "
        "(id, real_name, folder_name, screenscraper_id) "
        "VALUES ('cpc', 'Amstrad CPC', 'cpc', 65)",
      );
      await db.execute(
        "INSERT INTO app_system_folders (system_id, folder_name) "
        "VALUES ('cpc', 'amstradcpc')",
      );
      await db.execute(
        "INSERT INTO app_system_folders (system_id, folder_name) "
        "VALUES ('cpc', 'gx4000')",
      );

      await FortEsdeLibraryService.upsertPlatform(
        esdeSystemName: 'amstradcpc',
        appSystemId: 'cpc',
        displayName: 'Amstrad CPC',
        romDirectory: '/roms/amstradcpc',
        mediaDirectory: '/media/amstradcpc',
      );
      await FortEsdeLibraryService.upsertPlatform(
        esdeSystemName: 'gx4000',
        appSystemId: 'cpc',
        displayName: 'Amstrad GX4000',
        romDirectory: '/roms/gx4000',
        mediaDirectory: '/media/gx4000',
      );
    });

    tearDown(() async {
      await helper.tearDown();
    });

    test(
      'same filename can coexist in sibling platforms and keeps provenance',
      () async {
        const filename = 'Batman (Europe).zip';
        await db.execute(
          "INSERT INTO user_roms (app_system_id, filename, rom_path) "
          "VALUES ('cpc', '$filename', '/roms/amstradcpc/$filename')",
        );
        await db.execute(
          "INSERT INTO user_roms (app_system_id, filename, rom_path) "
          "VALUES ('cpc', '$filename', '/roms/gx4000/$filename')",
        );

        final tagged = await FortEsdeLibraryService.reconcileRomProvenance();
        expect(tagged, 2);

        final rows = await db.rawQuery(
          'SELECT rom_path, fort_esde_system_name FROM user_roms '
          'ORDER BY rom_path',
        );
        expect(rows, hasLength(2));
        expect(rows[0]['fort_esde_system_name'], 'amstradcpc');
        expect(rows[1]['fort_esde_system_name'], 'gx4000');
      },
    );

    test(
      'exposes sibling ES-DE platforms as separate visible systems',
      () async {
        await db.execute(
          "INSERT INTO user_roms (app_system_id, filename, rom_path) "
          "VALUES ('cpc', 'CPC Game.dsk', '/roms/amstradcpc/CPC Game.dsk')",
        );
        await db.execute(
          "INSERT INTO user_roms (app_system_id, filename, rom_path) "
          "VALUES ('cpc', 'GX Game.zip', '/roms/gx4000/GX Game.zip')",
        );

        final systems =
            await FortEsdeLibraryService.getDetectedPlatformSystems();
        expect(systems, hasLength(2));

        final cpc = systems.singleWhere(
          (system) => system.folderName == 'amstradcpc',
        );
        final gx = systems.singleWhere(
          (system) => system.folderName == 'gx4000',
        );

        expect(cpc.id, 'cpc');
        expect(gx.id, 'cpc');
        expect(cpc.realName, 'Amstrad CPC');
        expect(gx.realName, 'Amstrad GX4000');
        expect(cpc.romCount, 1);
        expect(gx.romCount, 1);
      },
    );

    test('loads games only from the requested ES-DE platform', () async {
      const filename = 'Shared Name.zip';
      await db.execute(
        "INSERT INTO user_roms (app_system_id, filename, rom_path) "
        "VALUES ('cpc', '$filename', '/roms/amstradcpc/$filename')",
      );
      await db.execute(
        "INSERT INTO user_roms (app_system_id, filename, rom_path) "
        "VALUES ('cpc', '$filename', '/roms/gx4000/$filename')",
      );

      final cpcGames = await FortEsdeLibraryService.getGamesForPlatform(
        'amstradcpc',
      );
      final gxGames = await FortEsdeLibraryService.getGamesForPlatform(
        'gx4000',
      );

      expect(cpcGames, hasLength(1));
      expect(gxGames, hasLength(1));
      expect(cpcGames.single.romPath, '/roms/amstradcpc/$filename');
      expect(gxGames.single.romPath, '/roms/gx4000/$filename');
      expect(cpcGames.single.systemFolderName, 'amstradcpc');
      expect(gxGames.single.systemFolderName, 'gx4000');
      // Both still inherit the same NeoStation emulator profile.
      expect(cpcGames.single.appSystemId, 'cpc');
      expect(gxGames.single.appSystemId, 'cpc');
    });
  });
}
