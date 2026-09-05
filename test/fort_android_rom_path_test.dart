import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/utils/fort_android_rom_path.dart';

void main() {
  const cdi = SystemModel(
    id: 'cdi',
    folderName: 'cdi',
    realName: 'Philips CD-i',
    iconImage: '',
    color: '#000000',
    folders: ['cdi', 'cdimono1', 'philipscdi'],
  );
  const odyssey2 = SystemModel(
    id: 'mo2',
    folderName: 'odyssey2',
    realName: 'Magnavox Odyssey2',
    iconImage: '',
    color: '#000000',
    folders: ['odyssey2', 'videopac'],
  );

  test('resolves primary ExternalStorageProvider document URI', () {
    const uri =
        'content://com.android.externalstorage.documents/tree/'
        'primary%3AROMs/document/primary%3AROMs%2Fcdimono1%2FGame.chd';

    expect(
      FortAndroidRomPath.externalStorageRealPath(uri),
      '/storage/emulated/0/ROMs/cdimono1/Game.chd',
    );
    expect(
      FortAndroidRomPath.fileDirectory(uri),
      '/storage/emulated/0/ROMs/cdimono1',
    );
    expect(FortAndroidRomPath.romRoot(uri, cdi), '/storage/emulated/0/ROMs');
  });

  test('resolves removable-storage ExternalStorageProvider document URI', () {
    const uri =
        'content://com.android.externalstorage.documents/tree/'
        '14F5-471E%3AROMs/document/'
        '14F5-471E%3AROMs%2Fcdimono1%2FSub%2FGame.chd';

    expect(
      FortAndroidRomPath.externalStorageRealPath(uri),
      '/storage/14F5-471E/ROMs/cdimono1/Sub/Game.chd',
    );
    expect(FortAndroidRomPath.romRoot(uri, cdi), '/storage/14F5-471E/ROMs');
  });

  test('leaves providers without a real external-storage mapping unresolved', () {
    const uri = 'content://example.provider/document/game.chd';
    expect(FortAndroidRomPath.externalStorageRealPath(uri), isNull);
    expect(FortAndroidRomPath.rawPath(uri), uri);
  });

  test('basename maps ES-DE ROMPROVIDER to the filename stem', () {
    expect(
      FortAndroidRomPath.basenameWithoutExtension('outrun.zip'),
      'outrun',
    );
  });

  test('MAME4droid rompath adds common removable-storage ROM root', () {
    const rom = '/storage/14F5-471E/ROMs/odyssey2/4 in 1 Row (Europe).zip';
    const cli =
        "-rompath '/storage/14F5-471E/ROMs/odyssey2;/storage/14F5-471E/ROMs/odyssey2' -cart '$rom'";

    expect(
      FortAndroidRomPath.ensureMameRomRoot(cli, rom, odyssey2),
      "-rompath '/storage/14F5-471E/ROMs/odyssey2;/storage/14F5-471E/ROMs' -cart '$rom'",
    );
  });

  test('MAME4droid rompath derives internal-storage root per game', () {
    const rom = '/storage/emulated/0/ROMs/odyssey2/Game.zip';
    const cli =
        "-rompath '/storage/emulated/0/ROMs/odyssey2;/storage/emulated/0/ROMs/odyssey2' -cart '$rom'";

    expect(
      FortAndroidRomPath.ensureMameRomRoot(cli, rom, odyssey2),
      "-rompath '/storage/emulated/0/ROMs/odyssey2;/storage/emulated/0/ROMs' -cart '$rom'",
    );
  });
}
