// One-off generator: replaces every app-icon slot with the new black-cat
// logo (D:/venera/dsh-image-gen/image-70c6cf52.png).
// Run from the unified root: `dart run tool/gen_app_icons_from_cat.dart [--preset=all|default]`.
// Afterwards run `dart run tool/gen_launcher_icos.dart` to rebuild the
// Windows runtime .ico presets from the new PNGs.
//
// Filenames are never renamed, so Contents.json / anydpi XML / manifests
// need no edits. iOS marketing + macOS icons are flattened opaque using the
// source corner pixel as fill (App Store rejects alpha in 1024).
import 'dart:io';

import 'package:image/image.dart';

/// Per-preset source artwork (args[0] overrides only the default preset).
const _presetSources = <String, String>{
  '': '../dsh-image-gen/image-70c6cf52.png',
  '_purple': '../dsh-image-gen/image-b739ec4c.png',
  '_green': '../dsh-image-gen/image-990e3650.png',
  '_orange': '../dsh-image-gen/image-b625f69e.png',
  '_silver': '../dsh-image-gen/image-a88b8ba6.png',
};

/// preset suffix -> android mipmap base name. '' == defaultIcon.
const _variants = <String, String>{
  '': 'ic_launcher',
  '_purple': 'ic_launcher_purple',
  '_green': 'ic_launcher_green',
  '_orange': 'ic_launcher_orange',
  '_silver': 'ic_launcher_silver',
};

const _densities = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

const _adaptive = <String, int>{
  'mdpi': 108,
  'hdpi': 162,
  'xhdpi': 216,
  'xxhdpi': 324,
  'xxxhdpi': 432,
};

const _ios = <String, int>{
  'AppIcon-20@2x.png': 40,
  'AppIcon-20@3x.png': 60,
  'AppIcon-29.png': 29,
  'AppIcon-29@2x.png': 58,
  'AppIcon-29@2x~ipad.png': 58,
  'AppIcon-29@3x.png': 87,
  'AppIcon-29~ipad.png': 29,
  'AppIcon-40@2x.png': 80,
  'AppIcon-40@2x~ipad.png': 80,
  'AppIcon-40@3x.png': 120,
  'AppIcon-40~ipad.png': 40,
  'AppIcon-60@2x~car.png': 120,
  'AppIcon-60@3x~car.png': 180,
  'AppIcon-20~ipad.png': 20,
  'AppIcon-20@2x~ipad.png': 40,
  'AppIcon-83.5@2x~ipad.png': 167,
  'AppIcon@2x.png': 120,
  'AppIcon@3x.png': 180,
  'AppIcon~ipad.png': 76,
  'AppIcon@2x~ipad.png': 152,
  'AppIcon~ios-marketing.png': 1024,
};

const _macos = <String, int>{
  'app_icon_16.png': 16,
  'app_icon_32.png': 32,
  'app_icon_64.png': 64,
  'app_icon_128.png': 128,
  'app_icon_256.png': 256,
  'app_icon_512.png': 512,
  'app_icon_1024.png': 1024,
};

int _written = 0;

void _write(String path, List<int> bytes) {
  final f = File(path);
  if (!f.parent.existsSync()) {
    stdout.writeln('skip (missing dir): $path');
    return;
  }
  f.writeAsBytesSync(bytes);
  _written++;
}

Image _square(Image src) {
  final s = src.width < src.height ? src.width : src.height;
  final x = (src.width - s) ~/ 2;
  final y = (src.height - s) ~/ 2;
  return copyCrop(src, x: x, y: y, width: s, height: s);
}

/// Opaque version: corner-pixel fill with the artwork composited on top.
Image _flatten(Image art) {
  final p = art.getPixel(0, 0);
  final out = Image(width: art.width, height: art.height);
  fill(out, color: ColorRgb8(p.r.toInt(), p.g.toInt(), p.b.toInt()));
  return compositeImage(out, art);
}

void main(List<String> args) {
  final onlyDefault = args.contains('--preset=default');
  final override = args.firstWhere(
    (a) => !a.startsWith('--'),
    orElse: () => '',
  );
  Image load(String suffix) {
    final srcPath = (suffix == '' && override != '')
        ? override
        : _presetSources[suffix]!;
    final decoded = decodePng(File(srcPath).readAsBytesSync());
    if (decoded == null) {
      stderr.writeln('cannot decode $srcPath');
      exit(1);
    }
    return decoded;
  }

  final names = onlyDefault ? [''] : _variants.keys.toList();

  // iOS / macOS / Windows exe icon / README always follow the default preset.
  final defaultArt = _square(load(''));
  final defaultFlat = _flatten(defaultArt);

  for (final suffix in names) {
    final base = _variants[suffix]!;
    final art = _square(load(suffix));
    final flat = _flatten(art);
    // 1. assets preview + in-app logo (512). Default has no suffix on
    // android but uses _default in assets/ (pubspec + launcher_icon.dart).
    final assetName =
        'assets/launcher_icon${suffix == '' ? '_default' : suffix}.png';
    _write(assetName, encodePng(copyResize(art, width: 512, height: 512)));
    // 2. android legacy + adaptive.
    _densities.forEach((d, px) {
      _write(
        'android/app/src/main/res/mipmap-$d/$base.png',
        encodePng(copyResize(flat, width: px, height: px)),
      );
    });
    _adaptive.forEach((d, px) {
      final dir = 'android/app/src/main/res/mipmap-$d/';
      _write(
        '$dir${base}_background.png',
        encodePng(copyResize(flat, width: px, height: px)),
      );
      final fg = Image(width: px, height: px);
      compositeImage(
        fg,
        copyResize(art, width: px * 2 ~/ 3, height: px * 2 ~/ 3),
        dstX: px ~/ 6,
        dstY: px ~/ 6,
      );
      _write('$dir${base}_foreground.png', encodePng(fg));
      // themed icon: white fill, alpha = luminance.
      final gray = grayscale(copyResize(art, width: px, height: px));
      final mono = Image(width: px, height: px);
      for (var y = 0; y < px; y++) {
        for (var x = 0; x < px; x++) {
          mono.setPixelRgba(x, y, 255, 255, 255, gray.getPixel(x, y).r.toInt());
        }
      }
      _write('$dir${base}_monochrome.png', encodePng(mono));
    });
  }

  // 3. iOS (opaque) + macOS.
  const iosDir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset/';
  _ios.forEach((name, px) {
    _write(
      '$iosDir$name',
      encodePng(copyResize(defaultFlat, width: px, height: px)),
    );
  });
  const macDir = 'macos/Runner/Assets.xcassets/AppIcon.appiconset/';
  _macos.forEach((name, px) {
    _write(
      '$macDir$name',
      encodePng(copyResize(defaultFlat, width: px, height: px)),
    );
  });

  // 4. Windows embedded exe icon.
  const winSizes = [16, 24, 32, 48, 64, 128, 256];
  final win = copyResize(
    defaultFlat,
    width: winSizes.first,
    height: winSizes.first,
  );
  for (final s in winSizes.skip(1)) {
    win.addFrame(copyResize(defaultFlat, width: s, height: s));
  }
  _write('windows/runner/resources/app_icon.ico', encodeIco(win));

  // 5. README header logo.
  _write(
    'assets/readme_logo.png',
    encodePng(copyResize(defaultArt, width: 512, height: 512)),
  );

  stdout.writeln('done: $_written files');
  stdout.writeln(
    'next: dart run tool/gen_launcher_icos.dart  (rebuilds assets/*.ico)',
  );
}
