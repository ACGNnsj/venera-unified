import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/launcher_icon.dart';
import 'package:venera_unified/foundation/tray.dart';

// Phase-2 Windows validation: the bundled multi-resolution .ico files the
// live window/taskbar/tray icon swaps between (task-12-phase2-winicons).
//
// Mapping logic itself is pinned by launcher_icon_test.dart; these tests pin
// the binary artifacts on disk: existence, ICO container header and the exact
// size ladder the generator promises (16/32/48/64/128/256).
void main() {
  group('windowsIcoAsset mapping', () {
    test('paths are pinned per preset', () {
      final assets = {
        for (final p in LauncherIconPreset.values) p.id: p.windowsIcoAsset,
      };
      expect(assets, {
        'default': 'assets/launcher_icon_default.ico',
        'purple': 'assets/launcher_icon_purple.ico',
        'green': 'assets/launcher_icon_green.ico',
        'orange': 'assets/launcher_icon_orange.ico',
        'silver': 'assets/launcher_icon_silver.ico',
      });
    });
  });

  group('bundled .ico artifacts', () {
    // flutter test runs with the package root as cwd.
    test('every preset ico exists and is non-empty', () {
      for (final preset in LauncherIconPreset.values) {
        final file = File(preset.windowsIcoAsset);
        expect(
          file.existsSync(),
          isTrue,
          reason: 'missing ${preset.windowsIcoAsset}',
        );
        expect(file.lengthSync(), greaterThan(0));
      }
    });

    test('ico headers carry the 16..256 size ladder', () {
      const expectedSizes = {16, 32, 48, 64, 128, 256};
      for (final preset in LauncherIconPreset.values) {
        final bytes = File(preset.windowsIcoAsset).readAsBytesSync();
        final data = ByteData.sublistView(bytes);
        // ICONDIR: reserved must be 0, type must be 1 (icon).
        expect(data.getUint16(0, Endian.little), 0);
        expect(data.getUint16(2, Endian.little), 1);
        final count = data.getUint16(4, Endian.little);
        expect(count, expectedSizes.length);
        final sizes = <int>{};
        for (var i = 0; i < count; i++) {
          final base = 6 + i * 16;
          final width = bytes[base] == 0 ? 256 : bytes[base];
          final height = bytes[base + 1] == 0 ? 256 : bytes[base + 1];
          expect(height, width, reason: 'entry $i of ${preset.id} not square');
          sizes.add(width);
          final byteCount = data.getUint32(base + 8, Endian.little);
          final offset = data.getUint32(base + 12, Endian.little);
          expect(byteCount, greaterThan(0));
          expect(offset + byteCount, lessThanOrEqualTo(bytes.length));
        }
        expect(sizes, expectedSizes);
      }
    });
  });

  group('tray preset hook', () {
    test('debugReset clears the windows icon hook', () {
      LauncherIconService.onWindowsIconChanged = (_) async {};
      TrayController.instance.debugReset();
      expect(LauncherIconService.onWindowsIconChanged, isNull);
    });
  });
}
