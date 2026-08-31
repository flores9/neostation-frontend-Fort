import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/fort_esde_library_service.dart';
import 'package:neostation/services/fort_esde_platform_reconciler.dart';
import 'package:neostation/services/fort_esde_scan_plan_service.dart';
import 'package:neostation/services/fort_system_path_service.dart';

import 'database_test_helper.dart';

void main() {
  group('Fort ES-DE platform identity', () {
    final helper = DatabaseTestHelper();
    late dynamic db;
    late Directory temp;

    const profile = SystemModel(
      id: 'cpc',
      folderName: 'cpc',
      realName: 'Amstrad CPC',
      iconImage: '',
      color: '#000000',
      folders: ['amstradcpc', 'gx4000'],
    );

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
      FortSystemPathService.invalidateCache();
      temp = await Directory.systemTemp.createTemp('neostation-fort-esde-');
    });

    tearDown(() async {
      FortSystemPathService.invalidateCache();
      if (await temp.exists()) await temp.delete(recursive: true);
      await helper.tearDown();
    });

    test('ES-DE gamelist identity suppresses weak canonical alias', () async {
      final root = temp.path.replaceAll('\\', '/');
      await _writeSettings(root);
      await Directory('$root/roms/cpc').create(recursive: true);
      await Directory('$root/roms/amstradcpc').create(recursive: true);
      await _writeGamelist(root, 'amstradcpc');

      final sources = await FortEsdeScanPlanService.resolve(
        profile,
        esdeRoot: root,
      );

      expect(sources.map((source) => source.esdeSystemName), ['amstradcpc']);
      expect(sources.single.romDirectory, '$root/roms/amstradcpc');
    });

    test('real ES-DE siblings survive on one NeoStation profile', () async {
      final root = temp.path.replaceAll('\\', '/');
      await _writeSettings(root);
      await Directory('$root/roms/cpc').create(recursive: true);
      await Directory('$root/roms/amstradcpc').create(recursive: true);
      await Directory('$root/roms/gx4000').create(recursive: true);
      await _writeGamelist(root, 'amstradcpc');
      await _writeGamelist(root, 'gx4000');

      final sources = await FortEsdeScanPlanService.resolve(
        profile,
        esdeRoot: root,
      );

      expect(
        sources.map((source) => source.esdeSystemName).toSet(),
        {'amstradcpc', 'gx4000'},
      );
      expect(
        sources.map((source) => source.esdeSystemName),
        isNot(contains('cpc')),
      );
    });

    test(
      'reconciles phantom canonical provenance without deleting ROM data',
      () async {
        await FortEsdeLibraryService.upsertPlatform(
          esdeSystemName: 'cpc',
          appSystemId: 'cpc',
          displayName: 'Amstrad CPC',
          romDirectory: '/roms/amstradcpc',
          mediaDirectory: '/media/cpc',
        );
        await db.execute('''
          INSERT INTO user_roms (
            app_system_id, filename, rom_path, is_favorite, play_time,
            fort_esde_system_name
          ) VALUES (
            'cpc', 'Batman.dsk', '/roms/amstradcpc/Batman.dsk', 1, 321, 'cpc'
          )
        ''');

        final removed = await FortEsdePlatformReconciler.reconcileProfile(
          appSystemId: 'cpc',
          activeSources: const {'amstradcpc': '/roms/amstradcpc'},
        );

        expect(removed, 1);
        final roms = await db.query('user_roms');
        expect(roms, hasLength(1));
        expect(roms.single['fort_esde_system_name'], 'amstradcpc');
        expect(roms.single['is_favorite'], 1);
        expect(roms.single['play_time'], 321);

        final stale = await db.query(
          FortEsdeLibraryService.tableName,
          where: 'esde_system_name = ?',
          whereArgs: ['cpc'],
        );
        expect(stale, isEmpty);
      },
    );

    test('shared active root remains ambiguous instead of picking an alias', () async {
      await FortEsdeLibraryService.upsertPlatform(
        esdeSystemName: 'legacy-cpc',
        appSystemId: 'cpc',
        displayName: 'Legacy CPC',
        romDirectory: '/shared',
        mediaDirectory: '/unknown-media',
      );
      await db.execute('''
        INSERT INTO user_roms (
          app_system_id, filename, rom_path, fort_esde_system_name
        ) VALUES (
          'cpc', 'Unknown.dsk', '/shared/Unknown.dsk', 'legacy-cpc'
        )
      ''');

      final removed = await FortEsdePlatformReconciler.reconcileProfile(
        appSystemId: 'cpc',
        activeSources: const {
          'amstradcpc': '/shared',
          'gx4000': '/shared',
        },
      );

      expect(removed, 0);
      final rom = (await db.query('user_roms')).single;
      expect(rom['fort_esde_system_name'], 'legacy-cpc');
      final stale = await db.query(
        FortEsdeLibraryService.tableName,
        where: 'esde_system_name = ?',
        whereArgs: ['legacy-cpc'],
      );
      expect(stale, hasLength(1));
    });
  });
}

Future<void> _writeSettings(String root) async {
  await Directory('$root/settings').create(recursive: true);
  await File('$root/settings/es_settings.xml').writeAsString('''
<string name="ROMDirectory" value="$root/roms" />
<string name="MediaDirectory" value="$root/media" />
<bool name="LegacyGamelistFileLocation" value="false" />
''');
}

Future<void> _writeGamelist(String root, String system) async {
  final directory = Directory('$root/gamelists/$system');
  await directory.create(recursive: true);
  await File('${directory.path}/gamelist.xml').writeAsString('<gameList />');
}
