import 'dart:ui' as ui;

import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/global_preference_store.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:venera_unified/foundation/reader_preferences.dart';

/// Reader Anime4K shader (GPU-baked Push sharpening).
///
/// The fragment shader is NEVER used for on-screen passes: its frag-coord
/// space would depend on DPR and ancestor transforms. Instead each page is
/// baked once at load into a cached ui.Image through an exact WxH offscreen
/// target, then drawn with the normal drawImageRect path (all BoxFit,
/// alignment and split-wide slices keep working unchanged).
///
/// Opt-in via [ReaderPreferences.anime4KShader] (default off); any load,
/// compile or bake failure returns null and the caller keeps the original.
abstract final class Anime4KShader {
  /// Asset path declared under `flutter.shaders` in pubspec.yaml.
  static const String assetPath = 'shaders/anime4k_push.frag';

  /// Push strength matching the native Anime4K v1 default (1/3).
  static const double strength = 1.0 / 3.0;

  /// Texture-coordinate precision guard: skip the bake when either side
  /// exceeds this (mobile GPUs degrade past 4096px), caller draws original.
  static const int maxSide = 4096;

  static ui.FragmentProgram? _program;
  static bool _unavailable = false;

  /// Whether the feature is switched on in settings.
  static bool get isEnabled => GlobalPreferenceStore(
    appdata.settings,
  ).read(ReaderPreferences.anime4KShader);

  /// Pure size guard, unit-testable without a GPU.
  static bool isEligibleSize(int width, int height) =>
      width > 0 && height > 0 && width <= maxSide && height <= maxSide;

  /// Bake [src] through the Push shader. Returns null when the program is
  /// unavailable, the image is oversized, or the bake throws.
  static Future<ui.Image?> bake(ui.Image src) async {
    if (_unavailable) return null;
    if (!isEligibleSize(src.width, src.height)) return null;
    try {
      _program ??= await ui.FragmentProgram.fromAsset(assetPath);
    } catch (e) {
      _unavailable = true;
      Log.error('Anime4KShader', 'fragment program unavailable: $e');
      return null;
    }
    try {
      final shader = _program!.fragmentShader();
      shader.setFloat(0, 1.0 / src.width);
      shader.setFloat(1, 1.0 / src.height);
      shader.setFloat(2, strength);
      shader.setImageSampler(0, src);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
        ui.Paint()..shader = shader,
      );
      final picture = recorder.endRecording();
      final baked = await picture.toImage(src.width, src.height);
      picture.dispose();
      shader.dispose();
      return baked;
    } catch (e) {
      Log.error('Anime4KShader', 'bake failed, using original: $e');
      return null;
    }
  }
}
