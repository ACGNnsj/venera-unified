import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_provider/upscale/acnet_ffi_pipeline.dart';

void main() {
  group('AcnetFfiPipeline.tilesFor', () {
    test('single core-sized image is one tile', () {
      final tiles = AcnetFfiPipeline.tilesFor(352, 352);
      expect(tiles, hasLength(1));
      expect(tiles.first.x, 0);
      expect(tiles.first.y, 0);
      expect(tiles.first.coreW, 352);
      expect(tiles.first.coreH, 352);
    });

    test('700x500 splits into a 2x2 grid with edge cores', () {
      final tiles = AcnetFfiPipeline.tilesFor(700, 500);
      expect(tiles, hasLength(4));
      expect([tiles[0].coreW, tiles[0].coreH], [352, 352]);
      expect([tiles[1].x, tiles[1].coreW], [352, 348]);
      expect([tiles[2].y, tiles[2].coreH], [352, 148]);
      expect([tiles[3].x, tiles[3].y], [352, 352]);
    });
  });

  group('AcnetFfiPipeline.tileMean', () {
    test('averages the tile core only', () {
      final plane = Uint8List.fromList([10, 20, 30, 40]);
      final tiles = AcnetFfiPipeline.tilesFor(2, 2);
      expect(AcnetFfiPipeline.tileMean(plane, 2, tiles.first), 25.0);
    });
  });

  group('AcnetFfiPipeline.committedMae', () {
    test('identical tiles score zero', () {
      final a = Float32List.fromList([0.1, 0.5, 0.9]);
      expect(AcnetFfiPipeline.committedMae(a, a), 0.0);
    });

    test('mean absolute difference', () {
      final a = Float32List.fromList([0.0, 1.0]);
      final b = Float32List.fromList([0.5, 0.5]);
      expect(AcnetFfiPipeline.committedMae(a, b), closeTo(0.5, 1e-9));
    });
  });

  group('AcnetDartFallback math', () {
    test('neutral gray round-trips', () {
      final rgba = Uint8List.fromList(
        List.filled(4, [128, 128, 128, 255]).expand((e) => e).toList(),
      );
      final split = AcnetDartFallback.rgbToYcrcb(rgba, 2, 2);
      expect(split.y, Uint8List.fromList([128, 128, 128, 128]));
      expect(split.cr, Uint8List.fromList([128, 128, 128, 128]));
      expect(split.cb, Uint8List.fromList([128, 128, 128, 128]));
    });

    test('extract replicates borders', () {
      final plane = Uint8List.fromList(List.generate(16, (i) => i));
      final tiles = AcnetFfiPipeline.tilesFor(4, 4);
      final out = AcnetDartFallback.extractTileF32(
        plane,
        4,
        4,
        1,
        tiles.first,
        4,
        1,
      )!;
      expect(out[0], 0.0);
      expect(out[1 * 4 + 1], 0.0);
      expect(out[2 * 4 + 2], closeTo(5 / 255, 1e-6));
      expect(out[3 * 4 + 3], closeTo(10 / 255, 1e-6));
    });

    test('commit identity at unit intensity', () {
      final tile = Float32List.fromList(List.generate(16, (i) => i / 15.0));
      final out = Uint8List(4);
      final ok = AcnetDartFallback.commitTileF32(
        tile,
        4,
        1,
        1,
        AcnetFfiPipeline.tilesFor(2, 2).first,
        1.0,
        out,
        2,
        2,
      );
      expect(ok, isTrue);
      expect(out, Uint8List.fromList([85, 102, 153, 170]));
    });

    test('merge white pixel is opaque white', () {
      final out = AcnetDartFallback.mergeYcrcbToRgba(
        Uint8List.fromList([255]),
        Uint8List.fromList([128]),
        Uint8List.fromList([128]),
        1,
        1,
        1,
      )!;
      expect(out, Uint8List.fromList([255, 255, 255, 255]));
    });

    test('non-ACNet channels are rejected', () {
      expect(
        AcnetDartFallback.extractTileF32(
          Uint8List(16),
          4,
          4,
          3,
          AcnetFfiPipeline.tilesFor(4, 4).first,
          4,
          1,
        ),
        isNull,
      );
    });
  });

  group('AcnetFfiPipeline.upscale contracts', () {
    test('non-ACNet channels short-circuit to null', () async {
      expect(
        await AcnetFfiPipeline.upscale(
          imageBytes: Uint8List(0),
          modelPath: 'missing.onnx',
          channels: 3,
        ),
        isNull,
      );
    });

    test('undecodable bytes return null', () async {
      expect(
        await AcnetFfiPipeline.upscale(
          imageBytes: Uint8List.fromList([0, 1, 2, 3]),
          modelPath: 'missing.onnx',
          channels: 1,
        ),
        isNull,
      );
    });
  });
}
