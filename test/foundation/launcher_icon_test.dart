import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/launcher_icon.dart';

void main() {
  group('LauncherIconPreset ids', () {
    test('stored ids are stable and unique', () {
      final ids = LauncherIconPreset.values.map((p) => p.id).toList();
      expect(ids, ['default', 'purple', 'green', 'orange', 'silver']);
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('fromId round-trips every preset', () {
      for (final preset in LauncherIconPreset.values) {
        expect(LauncherIconPreset.fromId(preset.id), preset);
      }
    });

    test('fromId falls back to default on unknown or null', () {
      expect(LauncherIconPreset.fromId('orig'), LauncherIconPreset.defaultIcon);
      expect(LauncherIconPreset.fromId('nope'), LauncherIconPreset.defaultIcon);
      expect(LauncherIconPreset.fromId(null), LauncherIconPreset.defaultIcon);
    });
  });

  group('native contract (phase 2 Manifest / Info.plist)', () {
    test('android aliases are pinned', () {
      final aliases = {
        for (final p in LauncherIconPreset.values) p.id: p.androidAlias,
      };
      expect(aliases, {
        'default': 'IconDefault',
        'purple': 'IconPurple',
        'green': 'IconGreen',
        'orange': 'IconOrange',
        'silver': 'IconSilver',
      });
    });

    test('ios keys match android aliases except default restores primary', () {
      for (final preset in LauncherIconPreset.values) {
        if (preset == LauncherIconPreset.defaultIcon) {
          expect(preset.iosIconName, isNull);
        } else {
          expect(preset.iosIconName, preset.androidAlias);
        }
      }
    });
  });

  group('bundled assets', () {
    test('logo and ico paths are distinct per preset', () {
      final logos = LauncherIconPreset.values.map((p) => p.inAppLogoAsset);
      final icos = LauncherIconPreset.values.map((p) => p.windowsIcoAsset);
      expect(logos.toSet(), hasLength(LauncherIconPreset.values.length));
      expect(icos.toSet(), hasLength(LauncherIconPreset.values.length));
    });

    test('ico mirrors the logo basename', () {
      for (final preset in LauncherIconPreset.values) {
        expect(preset.inAppLogoAsset, endsWith('.png'));
        expect(
          preset.windowsIcoAsset,
          '${preset.inAppLogoAsset.substring(0, preset.inAppLogoAsset.length - 4)}.ico',
        );
      }
    });
  });
}
