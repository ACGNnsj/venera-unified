import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_translation/translation_types.dart';
import 'package:venera_unified/foundation/image_translation/translation_worker.dart';

void main() {
  group('isScriptLetter', () {
    test('accepts CJK and ASCII letters', () {
      expect(isScriptLetter('A'.runes.single), isTrue);
      expect(isScriptLetter('z'.runes.single), isTrue);
      expect(isScriptLetter('\u{3042}'.runes.single), isTrue);
      expect(isScriptLetter('\u{4e2d}'.runes.single), isTrue);
      expect(isScriptLetter('\u{ac00}'.runes.single), isTrue);
    });

    test('rejects digits and punctuation', () {
      expect(isScriptLetter('1'.runes.single), isFalse);
      expect(isScriptLetter('.'.runes.single), isFalse);
      expect(isScriptLetter(' '.runes.single), isFalse);
    });
  });

  group('detectBlockLanguage', () {
    test('kana and hangul decide on their own', () {
      expect(detectBlockLanguage('\u{3053}\u{308c}\u{306f}', 'zh'), 'ja');
      expect(detectBlockLanguage('\u{b9cc}\u{d654}', 'en'), 'ko');
    });

    test('han follows a Chinese or Japanese engine', () {
      expect(detectBlockLanguage('Hello world', 'en'), 'en');
      expect(detectBlockLanguage('Hello world', 'zh'), 'en');
      expect(
        detectBlockLanguage('Bonjour', 'custom_ab12cd34'),
        'custom_ab12cd34',
      );
    });
  });

  group('resolveOcrPoolSize', () {
    test('mobile Japanese path stays single-worker', () {
      expect(
        resolveOcrPoolSize(
          requested: 0,
          processorCount: 8,
          isMobile: true,
          isDesktop: false,
          sourceLang: 'ja',
          hasJapaneseModel: true,
        ),
        1,
      );
      expect(
        resolveOcrPoolSize(
          requested: 0,
          processorCount: 8,
          isMobile: true,
          isDesktop: false,
          sourceLang: 'auto',
          hasJapaneseModel: true,
        ),
        1,
      );
    });

    test('explicit request is clamped by platform', () {
      expect(
        resolveOcrPoolSize(
          requested: 8,
          processorCount: 8,
          isMobile: true,
          isDesktop: false,
          sourceLang: 'en',
          hasJapaneseModel: false,
        ),
        2,
      );
      expect(
        resolveOcrPoolSize(
          requested: 8,
          processorCount: 8,
          isMobile: false,
          isDesktop: true,
          sourceLang: 'en',
          hasJapaneseModel: false,
        ),
        6,
      );
    });

    test('automatic is half the cores within platform caps', () {
      expect(
        resolveOcrPoolSize(
          requested: 0,
          processorCount: 8,
          isMobile: false,
          isDesktop: true,
          sourceLang: 'en',
          hasJapaneseModel: false,
        ),
        3,
      );
    });
  });

  group('OcrPageEngineHint', () {
    test('needs two agreeing observations', () {
      var hint = OcrPageEngineHint();
      expect(hint.preferredEngine, isNull);
      hint.observe(
        text: 'Hello there',
        language: 'en',
        engine: 'en',
        isVertical: false,
      );
      expect(hint.preferredEngine, isNull);
      hint.observe(
        text: 'Hello again',
        language: 'en',
        engine: 'en',
        isVertical: false,
      );
      expect(hint.preferredEngine, 'en');
    });

    test('disagreement disables the hint', () {
      var hint = OcrPageEngineHint();
      hint.observe(
        text: 'Hello there',
        language: 'en',
        engine: 'en',
        isVertical: false,
      );
      hint.observe(
        text: '\u{b9cc}\u{d654}\u{c5b4}\u{b2e4}',
        language: 'ko',
        engine: 'ko',
        isVertical: false,
      );
      expect(hint.preferredEngine, isNull);
    });
  });

  group('strongOcrEngineSignal', () {
    test('latin without han is an English signal', () {
      expect(
        strongOcrEngineSignal(
          text: 'Hello there',
          language: 'en',
          engine: 'en',
          isVertical: false,
        ),
        'en',
      );
    });

    test('language and engine mismatch is no signal', () {
      expect(
        strongOcrEngineSignal(
          text: 'Hello there',
          language: 'zh',
          engine: 'en',
          isVertical: false,
        ),
        isNull,
      );
    });
  });

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
  });

  group('resizeTextLine', () {
    test('rotation puts the top glyph first', () {
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
      expect(out.length, 8 * 4 * 4);
      expect(out[0], greaterThan(128));
      expect(out[(8 - 1) * 4], lessThan(128));
    });

    test('plain resample keeps output size', () {
      var src = RgbaImage(16, 8, Uint8List(16 * 8 * 4));
      var out = resizeTextLine(src, IntRect(0, 0, 16, 8), 32, 8);
      expect(out.length, 32 * 8 * 4);
    });
  });
}
