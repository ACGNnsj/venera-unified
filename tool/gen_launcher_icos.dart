// One-off generator: builds multi-resolution .ico files from the launcher-icon
// PNG presets so the Windows runtime can swap the live window/taskbar/tray icon
// (task-12, ported from VeneraX tool/gen_launcher_icos.dart).
// Run from the unified root: `dart run tool/gen_launcher_icos.dart`.
//
// The .exe's embedded icon is fixed at build time and stays app_icon.ico; these
// generated .ico files only feed WM_SETICON / the tray at runtime.
import 'dart:io';

import 'package:image/image.dart';

void main() {
  // preset PNG -> output .ico.
  const jobs = {
    'assets/launcher_icon_default.png': 'assets/launcher_icon_default.ico',
    'assets/launcher_icon_purple.png': 'assets/launcher_icon_purple.ico',
    'assets/launcher_icon_green.png': 'assets/launcher_icon_green.ico',
    'assets/launcher_icon_orange.png': 'assets/launcher_icon_orange.ico',
    'assets/launcher_icon_silver.png': 'assets/launcher_icon_silver.ico',
  };

  // Sizes Windows picks between for title bar (16), taskbar button (32) and
  // higher-DPI / Alt-Tab surfaces.
  const sizes = [16, 32, 48, 64, 128, 256];

  jobs.forEach((src, dst) {
    final decoded = decodePng(File(src).readAsBytesSync());
    if (decoded == null) {
      stderr.writeln('skip $src: not a PNG');
      return;
    }
    // encodeIco emits every frame of the image as a directory entry, so pack
    // all sizes into one Image.
    final image = copyResize(
      decoded,
      width: sizes.first,
      height: sizes.first,
      interpolation: Interpolation.average,
    );
    for (final s in sizes.skip(1)) {
      image.addFrame(
        copyResize(
          decoded,
          width: s,
          height: s,
          interpolation: Interpolation.average,
        ),
      );
    }
    File(dst).writeAsBytesSync(encodeIco(image));
    stdout.writeln('wrote $dst (${sizes.length} sizes)');
  });
}
