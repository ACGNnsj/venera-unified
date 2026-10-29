import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_translation/ocr_models.dart';
import 'package:venera_unified/foundation/image_translation/ocr_types.dart';
import 'package:venera_unified/foundation/image_translation/ocr_worker.dart';
import 'package:venera_unified/foundation/image_translation/public_translator.dart';

void main() {
  group('clusterOcrBoxes', () {
    test('merges stacked lines of one bubble', () {
      var lines = [
        IntRect(100, 100, 300, 130),
        IntRect(100, 140, 300, 170),
        IntRect(100, 180, 300, 210),
      ];
      var groups = clusterOcrBoxes(lines, 800, 1200);
      expect(groups.length, 1);
      expect(groups.single.length, 3);
    });

    test('keeps distant bubbles apart', () {
      var lines = [IntRect(100, 100, 300, 130), IntRect(500, 900, 700, 930)];
      var groups = clusterOcrBoxes(lines, 800, 1200);
      expect(groups.length, 2);
    });

    test('never merges horizontal and vertical text', () {
      var lines = [IntRect(100, 100, 300, 130), IntRect(120, 110, 150, 400)];
      var groups = clusterOcrBoxes(lines, 800, 1200);
      expect(groups.length, 2);
    });

    test('merges adjacent vertical columns', () {
      var lines = [IntRect(300, 100, 330, 400), IntRect(260, 110, 290, 390)];
      var groups = clusterOcrBoxes(lines, 800, 1200);
      expect(groups.length, 1);
    });
  });

  group('resizeTextLine', () {
    test('rotation puts the top glyph first', () {
      // 4x8 strip: top half red, bottom half blue.
      var pixels = Uint8List(4 * 8 * 4);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 4; x++) {
          var i = (y * 4 + x) * 4;
          var topHalf = y < 4;
          pixels[i] = topHalf ? 255 : 0;
          pixels[i + 1] = 0;
          pixels[i + 2] = topHalf ? 0 : 255;
          pixels[i + 3] = 255;
        }
      }
      var src = RgbaImage(4, 8, pixels);
      var out = resizeTextLine(src, IntRect(0, 0, 4, 8), 8, 4, rotate: true);
      // Leftmost column samples the source top (red), rightmost the bottom.
      var leftRed = out[0];
      var rightRed = out[(8 - 1) * 4];
      expect(leftRed, greaterThan(128));
      expect(rightRed, lessThan(128));
    });

    test('plain resize keeps dimensions', () {
      var src = RgbaImage(10, 10, Uint8List(10 * 10 * 4));
      var out = resizeTextLine(src, IntRect(0, 0, 10, 10), 48, 48);
      expect(out.length, 48 * 48 * 4);
    });
  });

  group('detPostprocess', () {
    test('finds one box for a bright blob', () {
      const w = 32, h = 32;
      var probs = Float32List(w * h);
      for (var y = 10; y < 20; y++) {
        for (var x = 8; x < 22; x++) {
          probs[y * w + x] = 0.9;
        }
      }
      var boxes = detPostprocess(probs, w, h, 320, 320);
      expect(boxes.length, 1);
      // The box covers the blob area (scaled x10) plus unclip dilation.
      expect(boxes.single.left, lessThan(80));
      expect(boxes.single.right, greaterThan(220));
    });

    test('drops tiny components', () {
      const w = 32, h = 32;
      var probs = Float32List(w * h);
      probs[5 * w + 5] = 0.9;
      probs[5 * w + 6] = 0.9;
      expect(detPostprocess(probs, w, h, 320, 320), isEmpty);
    });

    test('drops low-score blobs', () {
      const w = 32, h = 32;
      var probs = Float32List(w * h);
      for (var y = 10; y < 20; y++) {
        for (var x = 8; x < 22; x++) {
          probs[y * w + x] = 0.35;
        }
      }
      expect(detPostprocess(probs, w, h, 320, 320), isEmpty);
    });
  });

  group('detectBlockLanguage', () {
    test('kana decides Japanese', () {
      expect(detectBlockLanguage('こんにちは', 'ja'), 'ja');
    });

    test('han follows the engine', () {
      expect(detectBlockLanguage('漢字テスト', 'ja'), 'ja');
      expect(detectBlockLanguage('汉字', 'en'), 'zh');
    });

    test('latin is English for built-in engines', () {
      expect(detectBlockLanguage('HELLO', 'ja'), 'en');
    });
  });

  group('PublicTranslator pure parts', () {
    test('chunks split at the line cap', () {
      var texts = List<String>.generate(70, (i) => 'line $i');
      var chunks = PublicTranslator.chunksForTest(texts);
      expect(chunks.length, 2);
      expect(chunks[0].length, 64);
      expect(chunks[1].length, 6);
    });

    test('a single long line goes out alone', () {
      var texts = ['x' * 7000, 'short'];
      var chunks = PublicTranslator.chunksForTest(texts);
      expect(chunks.length, 2);
      expect(chunks[0], ['x' * 7000]);
    });

    test('parse accepts both response shapes', () {
      expect(PublicTranslator.parseForTest(['译文一', '译文二'], 2), ['译文一', '译文二']);
      expect(
        PublicTranslator.parseForTest([
          ['译文一', 'ja'],
          ['译文二', 'ja'],
        ], 2),
        ['译文一', '译文二'],
      );
    });

    test('parse rejects length mismatch', () {
      expect(() => PublicTranslator.parseForTest(['only'], 2), throwsException);
    });

    test('parse unescapes entities', () {
      expect(PublicTranslator.parseForTest(['fish &amp; chips'], 1), [
        'fish & chips',
      ]);
    });
  });

  group('ocr model pins', () {
    test('three assets with locked revision and sizes', () {
      var assets = ocrModelAssets();
      expect(assets.length, 3);
      for (var asset in assets) {
        expect(asset.url, contains('revision=$kOcrModelRevision'));
        expect(asset.sha256.length, 64);
        expect(asset.bytes, greaterThan(0));
      }
      expect(ocrModelsTotalBytes(), 4745517 + 9753335 + 17332);
    });
  });
}
