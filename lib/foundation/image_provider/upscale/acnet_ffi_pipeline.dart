import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:venera_unified/foundation/image_translation/ort_ffi.dart';
import 'package:venera_unified/foundation/log.dart';

import 'anime4k_native.dart';

/// Cross-platform ACNet 2x super-resolution over [OrtFfiSession].
///
/// Same tiling math as Android-native UpscaleEngine.kt: fixed 384px tiles
/// with 16px BORDER_REPLICATE padding (352px effective core), Y channel
/// through ONNX, chroma bilinear-upsampled, BT.601 merge. Session EP order
/// (DirectML / CoreML / XNNPACK / CPU) comes from
/// [OrtFfiSession.open]; the first content tile is dual-run against a CPU
/// session and the EP result is dropped when normalized MAE exceeds
/// [maxContentMae] (mirrors the OCR worker self-check).
///
/// Returns null when the model is not ACNet-shaped, the native helpers and
/// their Dart fallbacks both fail, or inference throws: callers keep the
/// original image (see upscale_gate.dart). Heavy work runs in a spawned
/// isolate via [compute]; transient spawn failure falls back to the current
/// isolate like Anime4KUpscaler.processInIsolate.
abstract final class AcnetFfiPipeline {
  /// Fixed ONNX input edge (avoids dynamic-shape recompile on DML/CoreML).
  static const int tileIn = 384;

  /// Replicated border around each tile.
  static const int pad = 16;

  /// Effective unpadded core edge.
  static const int core = tileIn - pad * 2;

  /// ACNet upscale factor.
  static const int scale = 2;

  /// Normalized MAE gate for the first-tile EP-vs-CPU self-check.
  static const double maxContentMae = 0.04;

  /// Content-tile luma bounds: skip near-flat tiles for the EP self-check.
  static const int contentLo = 4;
  static const int contentHi = 251;

  /// Grid of tiles covering a wxh plane. Pure, unit-tested.
  static List<AcnetTile> tilesFor(int w, int h) {
    final tiles = <AcnetTile>[];
    for (var y = 0; y < h; y += core) {
      for (var x = 0; x < w; x += core) {
        tiles.add(
          AcnetTile(
            x: x,
            y: y,
            coreW: (w - x).clamp(0, core),
            coreH: (h - y).clamp(0, core),
          ),
        );
      }
    }
    return tiles;
  }

  /// Mean luma of a tile core, unit-testable.
  static double tileMean(Uint8List plane, int w, AcnetTile t) {
    var sum = 0;
    for (var r = 0; r < t.coreH; r++) {
      final base = (t.y + r) * w + t.x;
      for (var c = 0; c < t.coreW; c++) {
        sum += plane[base + c];
      }
    }
    return sum / (t.coreW * t.coreH);
  }

  /// MAE between two model-output float tiles (already normalized),
  /// unit-testable.
  static double committedMae(Float32List a, Float32List b) {
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum / a.length;
  }

  static Future<Uint8List?> upscale({
    required Uint8List imageBytes,
    required String modelPath,
    required int channels,
    double intensity = 1.0,
  }) async {
    // 3-channel Real-ESRGAN stays on the Android MethodChannel path for now.
    if (channels != 1) return null;
    final params = _AcnetParams(
      imageBytes: imageBytes,
      modelPath: modelPath,
      intensity: intensity,
    );
    try {
      return await compute(_run, params);
    } catch (e, s) {
      Log.error('ACNet', 'isolate failed, retry inline: $e\n$s');
      return _run(params);
    }
  }

  static Uint8List? _run(_AcnetParams p) {
    OrtFfiSession? session;
    OrtFfiSession? cpuSession;
    try {
      final src = img.decodeImage(p.imageBytes);
      if (src == null) {
        Log.error('ACNet', 'decode failed');
        return null;
      }
      final w = src.width;
      final h = src.height;
      if (w <= 0 || h <= 0) return null;
      final rgba = src.getBytes(order: img.ChannelOrder.rgba);

      final split =
          Anime4KNative.rgbToYcrcb(rgba, w, h) ??
          AcnetDartFallback.rgbToYcrcb(rgba, w, h);

      session = OrtFfiSession.open(p.modelPath);
      var current = session;
      final inputName = current.inputNames.isNotEmpty
          ? session.inputNames.first
          : 'input';
      final outputName = session.outputNames.isNotEmpty
          ? session.outputNames.first
          : 'output';
      // EP session that already fell back to CPU needs no self-check.
      var verified = session.executionProvider == null;

      final ow = w * scale;
      final oh = h * scale;
      final yUp = Uint8List(ow * oh);
      for (final t in tilesFor(w, h)) {
        final tileF32 =
            Anime4KNative.extractTileF32(
              split.y,
              w,
              h,
              1,
              t.x,
              t.y,
              t.coreW,
              t.coreH,
              tileIn,
              pad,
            ) ??
            AcnetDartFallback.extractTileF32(split.y, w, h, 1, t, tileIn, pad);
        if (tileF32 == null) return null;
        final epOut = _runTile(current, inputName, outputName, tileF32);
        if (epOut == null) return null;
        var committed = epOut;
        if (!verified) {
          verified = true;
          final mean = tileMean(split.y, w, t);
          if (mean >= contentLo && mean <= contentHi) {
            try {
              final cpu = cpuSession ?? OrtFfiSession.openCpu(p.modelPath);
              cpuSession = cpu;
              final cpuOut = _runTile(
                cpu,
                cpu.inputNames.isNotEmpty ? cpu.inputNames.first : 'input',
                cpu.outputNames.isNotEmpty ? cpu.outputNames.first : 'output',
                tileF32,
              );
              if (cpuOut != null) {
                final mae = committedMae(epOut, cpuOut);
                if (mae > maxContentMae) {
                  Log.warning(
                    'ACNet',
                    'EP output deviates (MAE ${mae.toStringAsFixed(4)}), using CPU',
                  );
                  current.close();
                  session = cpu;
                  current = cpu;
                  cpuSession = null;
                  committed = cpuOut;
                }
              }
            } catch (e) {
              Log.error('ACNet', 'CPU check failed, trusting EP: $e');
            }
          }
        }
        final ok =
            Anime4KNative.commitTileF32(
              committed,
              1,
              tileIn,
              pad,
              scale,
              t.x,
              t.y,
              t.coreW,
              t.coreH,
              p.intensity,
              ow,
              oh,
              yUp,
            ) ??
            AcnetDartFallback.commitTileF32(
              committed,
              tileIn,
              pad,
              scale,
              t,
              p.intensity,
              yUp,
              ow,
              oh,
            );
        if (ok == null || !ok) return null;
      }

      final outRgba =
          Anime4KNative.mergeYcrcbToRgba(
            yUp,
            split.cr,
            split.cb,
            w,
            h,
            scale,
          ) ??
          AcnetDartFallback.mergeYcrcbToRgba(
            yUp,
            split.cr,
            split.cb,
            w,
            h,
            scale,
          );
      if (outRgba == null) return null;
      final out = img.Image.fromBytes(
        width: ow,
        height: oh,
        bytes: outRgba.buffer,
        order: img.ChannelOrder.rgba,
      );
      return Uint8List.fromList(img.encodePng(out));
    } catch (e, s) {
      Log.error('ACNet', 'pipeline failed: $e\n$s');
      return null;
    } finally {
      session?.close();
      cpuSession?.close();
    }
  }

  static Float32List? _runTile(
    OrtFfiSession session,
    String inputName,
    String outputName,
    Float32List tile,
  ) {
    try {
      final result = session.run({
        inputName: OrtInput.float32(tile, [1, 1, tileIn, tileIn]),
      });
      final out = result[outputName];
      if (out == null || out.data.length != tileIn * scale * tileIn * scale) {
        return null;
      }
      return out.data;
    } catch (e) {
      Log.error('ACNet', 'tile inference failed: $e');
      return null;
    }
  }
}

class AcnetTile {
  const AcnetTile({
    required this.x,
    required this.y,
    required this.coreW,
    required this.coreH,
  });

  final int x;
  final int y;
  final int coreW;
  final int coreH;
}

class _AcnetParams {
  const _AcnetParams({
    required this.imageBytes,
    required this.modelPath,
    required this.intensity,
  });

  final Uint8List imageBytes;
  final String modelPath;
  final double intensity;
}

/// Split planes. Record shape matches [Anime4KNative.rgbToYcrcb] so the
/// native fast path and the Dart fallback are interchangeable with ??.
typedef AcnetYcrcb = ({Uint8List y, Uint8List cr, Uint8List cb});

/// Pure-Dart mirror of the native ACNet helpers (same BT.601 / replicate /
/// bilinear math in float64). Used when libvenera_anime4k is not bundled for
/// the current platform, so the FFI pipeline degrades instead of dying.
/// Public for unit tests; prefer the native fast path at runtime.
abstract final class AcnetDartFallback {
  static double _q(double v) => v.round().clamp(0, 255).toDouble();

  static AcnetYcrcb rgbToYcrcb(Uint8List rgba, int w, int h) {
    final n = w * h;
    final y = Uint8List(n);
    final cr = Uint8List(n);
    final cb = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final r = rgba[i * 4].toDouble();
      final g = rgba[i * 4 + 1].toDouble();
      final b = rgba[i * 4 + 2].toDouble();
      final yy = 0.299 * r + 0.587 * g + 0.114 * b;
      y[i] = _q(yy).toInt();
      cr[i] = _q((r - yy) * 0.713 + 128.0).toInt();
      cb[i] = _q((b - yy) * 0.564 + 128.0).toInt();
    }
    return (y: y, cr: cr, cb: cb);
  }

  static Float32List? extractTileF32(
    Uint8List plane,
    int w,
    int h,
    int channels,
    AcnetTile t,
    int tileIn,
    int pad,
  ) {
    if (channels != 1) return null;
    final out = Float32List(tileIn * tileIn);
    for (var ty = 0; ty < tileIn; ty++) {
      final sy = (t.y + ty - pad).clamp(0, h - 1);
      for (var tx = 0; tx < tileIn; tx++) {
        final sx = (t.x + tx - pad).clamp(0, w - 1);
        out[ty * tileIn + tx] = plane[sy * w + sx] / 255.0;
      }
    }
    return out;
  }

  static bool? commitTileF32(
    Float32List committed,
    int tileIn,
    int pad,
    int scale,
    AcnetTile t,
    double intensity,
    Uint8List outPlane,
    int outW,
    int outH,
  ) {
    if (committed.length != tileIn * scale * tileIn * scale) return null;
    final spatial = tileIn * scale;
    for (var oy = 0; oy < t.coreH * scale; oy++) {
      final gy = t.y * scale + oy;
      if (gy >= outH) continue;
      for (var ox = 0; ox < t.coreW * scale; ox++) {
        final gx = t.x * scale + ox;
        if (gx >= outW) continue;
        final v = committed[(pad * scale + oy) * spatial + pad * scale + ox];
        outPlane[gy * outW + gx] = _q(
          ((v - 0.5) * intensity + 0.5) * 255.0,
        ).toInt();
      }
    }
    return true;
  }

  static Uint8List? mergeYcrcbToRgba(
    Uint8List yUp,
    Uint8List cr,
    Uint8List cb,
    int w,
    int h,
    int scale,
  ) {
    final ow = w * scale;
    final oh = h * scale;
    if (yUp.length != ow * oh) return null;
    final out = Uint8List(ow * oh * 4);
    for (var dy = 0; dy < oh; dy++) {
      final sy = (dy + 0.5) / scale - 0.5;
      final y0 = sy.floor().clamp(0, h - 1);
      final y1 = (y0 + 1).clamp(0, h - 1);
      final fy = (sy - y0).clamp(0.0, 1.0);
      for (var dx = 0; dx < ow; dx++) {
        final sx = (dx + 0.5) / scale - 0.5;
        final x0 = sx.floor().clamp(0, w - 1);
        final x1 = (x0 + 1).clamp(0, w - 1);
        final fx = (sx - x0).clamp(0.0, 1.0);
        final crv =
            cr[y0 * w + x0] * (1 - fx) * (1 - fy) +
            cr[y0 * w + x1] * fx * (1 - fy) +
            cr[y1 * w + x0] * (1 - fx) * fy +
            cr[y1 * w + x1] * fx * fy;
        final cbv =
            cb[y0 * w + x0] * (1 - fx) * (1 - fy) +
            cb[y0 * w + x1] * fx * (1 - fy) +
            cb[y1 * w + x0] * (1 - fx) * fy +
            cb[y1 * w + x1] * fx * fy;
        final yy = yUp[dy * ow + dx].toDouble();
        final o = (dy * ow + dx) * 4;
        out[o] = _q(yy + 1.403 * (crv - 128)).toInt();
        out[o + 1] = _q(yy - 0.714 * (crv - 128) - 0.344 * (cbv - 128)).toInt();
        out[o + 2] = _q(yy + 1.773 * (cbv - 128)).toInt();
        out[o + 3] = 255;
      }
    }
    return out;
  }
}
