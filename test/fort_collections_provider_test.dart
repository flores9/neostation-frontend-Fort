import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/collections_provider.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseTestHelper helper;

  GameModel gameAt(String? romPath) => GameModel(
    romname: 'Game.zip',
    realname: 'Game',
    name: 'Game',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0.0,
    romPath: romPath,
  );

  setUp(() async {
    helper = DatabaseTestHelper();
    final db = await helper.setUp();
    await SqliteMigrations.migrateToVersion(db.rawDb, 139);
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, short_name) "
      "VALUES ('sys-nes', 'Nintendo Entertainment System', 'nes', 'NES')",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) "
      "VALUES ('Game.zip', '/roms/nes/Game.zip', 'sys-nes')",
    );
  });

  tearDown(() async {
    await helper.tearDown();
  });

  test('provider verifies a collection membership after writing it', () async {
    final provider = CollectionsProvider();
    final collection = await provider.create('Test');

    await provider.addGame(collection.id, gameAt('/roms/nes/Game.zip'));

    expect(
      await provider.collectionIdsFor(gameAt('/roms/nes/Game.zip')),
      {collection.id},
    );
  });

  test('provider never reports success when a game has no persistent ROM path', () async {
    final provider = CollectionsProvider();
    final collection = await provider.create('Test');

    await expectLater(
      provider.addGame(collection.id, gameAt(null)),
      throwsA(isA<StateError>()),
    );
  });
}
