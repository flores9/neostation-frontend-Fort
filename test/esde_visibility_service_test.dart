import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/services/esde_visibility_service.dart';

import 'database_test_helper.dart';

void main() {
  late DatabaseTestHelper helper;

  setUp(() async {
    helper = DatabaseTestHelper();
    final db = await helper.setUp();
    await db.insert('user_config', {
      'id': 1,
      'esde_folder_path': '/fake/es-de',
    });
  });

  tearDown(() async {
    await helper.tearDown();
  });

  test('gamelist membership filters ROMs discovered after ES-DE import', () async {
    await EsdeVisibilityService.prepareImport();
    await EsdeVisibilityService.recordSystemMembership('cdi', [
      '7th Guest, The (Disc 1 of 2).chd',
    ]);

    final games = [
      DatabaseGameModel(
        appSystemId: 'cdi',
        filename: '7th Guest, The (Disc 1 of 2).chd',
        romPath: '/roms/cdi/disc1.chd',
      ),
      DatabaseGameModel(
        appSystemId: 'cdi',
        filename: '7th Guest, The (Disc 2 of 2).chd',
        romPath: '/roms/cdi/disc2.chd',
      ),
    ];

    final visible = await EsdeVisibilityService.filterLibraryGames(games);

    expect(visible.map((g) => g.filename), [
      '7th Guest, The (Disc 1 of 2).chd',
    ]);
  });

  test('systems with no recorded gamelist remain unaffected', () async {
    await EsdeVisibilityService.prepareImport();

    final game = DatabaseGameModel(
      appSystemId: 'nes',
      filename: 'Mario.nes',
      romPath: '/roms/nes/Mario.nes',
    );

    final visible = await EsdeVisibilityService.filterLibraryGames([game]);

    expect(visible, [game]);
  });
}
