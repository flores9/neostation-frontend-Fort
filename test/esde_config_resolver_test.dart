import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/esde_config_resolver.dart';

void main() {
  group('EsdeConfigResolver', () {
    test('parses ES-DE multi-root settings including external media', () {
      const xml = '''<?xml version="1.0"?>
<bool name="LegacyGamelistFileLocation" value="false" />
<string name="ROMDirectory" value="/storage/emulated/0/ROMs" />
<string name="MediaDirectory" value="/storage/14F5-471E/ROMs" />
''';

      final settings = EsdeConfigResolver.parseSettings(xml);

      expect(settings.romDirectory, '/storage/emulated/0/ROMs');
      expect(settings.mediaDirectory, '/storage/14F5-471E/ROMs');
      expect(settings.legacyGamelistFileLocation, isFalse);
    });

    test('resolves percent ROMPATH and preserves absolute custom paths', () {
      const xml = '''<?xml version="1.0"?>
<systemList>
  <system>
    <name>snes</name>
    <path>%ROMPATH%/snes</path>
  </system>
  <system>
    <name>psx</name>
    <path>/storage/14F5-471E/ROMs/psx</path>
  </system>
  <system>
    <name>ps2</name>
    <path>/storage/emulated/0/ROMs/ps2</path>
  </system>
</systemList>
''';

      final paths = EsdeConfigResolver.parseCustomSystemPaths(
        xml,
        romDirectory: '/storage/emulated/0/ROMs',
      );

      expect(paths['snes'], '/storage/emulated/0/ROMs/snes');
      expect(paths['psx'], '/storage/14F5-471E/ROMs/psx');
      expect(paths['ps2'], '/storage/emulated/0/ROMs/ps2');
    });

    test('preserves distinct ES-DE platforms that share an emulator profile', () {
      const xml = '''
<systemList>
  <system>
    <name>amstradcpc</name>
    <fullname>Amstrad CPC</fullname>
    <path>/storage/14F5-471E/ROMs/amstradcpc</path>
    <extension>.dsk .m3u</extension>
    <platform>amstradcpc</platform>
    <theme>amstradcpc</theme>
  </system>
  <system>
    <name>gx4000</name>
    <fullname>Amstrad GX4000</fullname>
    <path>/storage/14F5-471E/ROMs/gx4000</path>
    <extension>.zip .bin</extension>
    <platform>gx4000</platform>
    <theme>gx4000</theme>
  </system>
</systemList>
''';

      final systems = EsdeConfigResolver.parseCustomSystems(xml);

      expect(systems.keys, containsAll(<String>['amstradcpc', 'gx4000']));
      expect(systems['amstradcpc']!.fullName, 'Amstrad CPC');
      expect(systems['amstradcpc']!.theme, 'amstradcpc');
      expect(systems['amstradcpc']!.platformTags, ['amstradcpc']);
      expect(systems['amstradcpc']!.extensions, ['.dsk', '.m3u']);
      expect(systems['gx4000']!.fullName, 'Amstrad GX4000');
      expect(
        systems['gx4000']!.romDirectory,
        '/storage/14F5-471E/ROMs/gx4000',
      );
    });

    test('preserves megadrive and megadrivejp as separate ES-DE platforms', () {
      const xml = '''
<systemList>
  <system>
    <name>megadrive</name>
    <fullname>Sega Mega Drive</fullname>
    <path>/roms/megadrive</path>
    <platform>megadrive</platform>
  </system>
  <system>
    <name>megadrivejp</name>
    <fullname>Sega Mega Drive Japan</fullname>
    <path>/roms/megadrivejp</path>
    <platform>megadrive</platform>
  </system>
</systemList>
''';

      final systems = EsdeConfigResolver.parseCustomSystems(xml);

      expect(systems.length, 2);
      expect(systems['megadrive']!.name, 'megadrive');
      expect(systems['megadrivejp']!.name, 'megadrivejp');
      expect(systems['megadrive']!.romDirectory, '/roms/megadrive');
      expect(systems['megadrivejp']!.romDirectory, '/roms/megadrivejp');
    });

    test('does not guess unresolved percent ROMPATH', () {
      const xml = '''
<systemList>
  <system>
    <name>snes</name>
    <path>%ROMPATH%/snes</path>
  </system>
</systemList>
''';

      final paths = EsdeConfigResolver.parseCustomSystemPaths(xml);

      expect(paths, isEmpty);
    });

    test('keeps ROM and media roots independent for a system', () {
      final config = EsdeResolvedConfig(
        esdeRoot: '/storage/emulated/0/ES-DE',
        settings: const EsdePathSettings(
          romDirectory: '/storage/emulated/0/ROMs',
          mediaDirectory: '/storage/14F5-471E/ROMs',
        ),
        customSystemRomPaths: const {
          'psx': '/storage/14F5-471E/ROMs/psx',
          'ps2': '/storage/emulated/0/ROMs/ps2',
        },
      );

      final ps2 = config.forSystem('ps2');
      expect(ps2.romDirectory, '/storage/emulated/0/ROMs/ps2');
      expect(ps2.mediaDirectory, '/storage/14F5-471E/ROMs/ps2');
      expect(ps2.gamelistCandidates, [
        '/storage/emulated/0/ES-DE/gamelists/ps2/gamelist.xml',
        '/storage/emulated/0/ROMs/ps2/gamelist.xml',
      ]);

      final psx = config.forSystem('psx');
      expect(psx.romDirectory, '/storage/14F5-471E/ROMs/psx');
      expect(psx.mediaDirectory, '/storage/14F5-471E/ROMs/psx');
    });

    test('legacy mode prefers ROM-local gamelist', () {
      final config = EsdeResolvedConfig(
        esdeRoot: '/storage/emulated/0/ES-DE',
        settings: const EsdePathSettings(
          romDirectory: '/storage/emulated/0/ROMs',
          legacyGamelistFileLocation: true,
        ),
        customSystemRomPaths: const {},
      );

      expect(config.forSystem('snes').gamelistCandidates, [
        '/storage/emulated/0/ROMs/snes/gamelist.xml',
        '/storage/emulated/0/ES-DE/gamelists/snes/gamelist.xml',
      ]);
    });

    test('default media fallback remains downloaded_media', () {
      final config = EsdeResolvedConfig(
        esdeRoot: '/storage/emulated/0/ES-DE',
        settings: const EsdePathSettings(),
        customSystemRomPaths: const {},
      );

      expect(
        config.forSystem('snes').mediaDirectory,
        '/storage/emulated/0/ES-DE/downloaded_media/snes',
      );
    });
  });
}
