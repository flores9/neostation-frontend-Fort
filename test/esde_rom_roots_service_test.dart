import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/esde_rom_roots_service.dart';
import 'package:path/path.dart' as p;

void main() {
  group('EsdeRomRootsService.discoverRomRoots', () {
    late Directory esdeRoot;

    setUp(() {
      esdeRoot = Directory.systemTemp.createTempSync('fort_esde_roots_');
      Directory(p.join(esdeRoot.path, 'settings')).createSync(recursive: true);
      Directory(p.join(esdeRoot.path, 'custom_systems'))
          .createSync(recursive: true);
    });

    tearDown(() => esdeRoot.deleteSync(recursive: true));

    test('combines ROMDirectory with an absolute custom-system storage root', () {
      File(p.join(esdeRoot.path, 'settings', 'es_settings.xml')).writeAsStringSync(
        '<string name="ROMDirectory" value="/storage/14F5-471E/ROMs" />',
      );
      File(p.join(esdeRoot.path, 'custom_systems', 'es_systems.xml'))
          .writeAsStringSync('''
<systemList>
  <system>
    <name>megadrive</name>
    <path>/storage/14F5-471E/ROMs/megadrive</path>
  </system>
  <system>
    <name>cdimono1</name>
    <path>/storage/emulated/0/ROMs/cdimono1</path>
  </system>
</systemList>
''');

      expect(
        EsdeRomRootsService.discoverRomRoots(esdeRoot.path),
        ['/storage/14F5-471E/ROMs', '/storage/emulated/0/ROMs'],
      );
    });

    test('does not create redundant nested roots under ROMDirectory', () {
      File(p.join(esdeRoot.path, 'settings', 'es_settings.xml')).writeAsStringSync(
        '<string name="ROMDirectory" value="/roms" />',
      );
      File(p.join(esdeRoot.path, 'custom_systems', 'es_systems.xml'))
          .writeAsStringSync('''
<systemList>
  <system><name>a</name><path>/roms/a</path></system>
  <system><name>b</name><path>/roms/nested/b</path></system>
</systemList>
''');

      expect(EsdeRomRootsService.discoverRomRoots(esdeRoot.path), ['/roms']);
    });

    test('expands %ROMPATH% without adding another root', () {
      File(p.join(esdeRoot.path, 'settings', 'es_settings.xml')).writeAsStringSync(
        '<string name="ROMDirectory" value="/roms" />',
      );
      File(p.join(esdeRoot.path, 'custom_systems', 'es_systems.xml'))
          .writeAsStringSync('''
<systemList>
  <system><name>a</name><path>%ROMPATH%/a</path></system>
</systemList>
''');

      expect(EsdeRomRootsService.discoverRomRoots(esdeRoot.path), ['/roms']);
    });
  });
}
