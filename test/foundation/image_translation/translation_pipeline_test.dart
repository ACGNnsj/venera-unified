import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/opencc_table.dart';
import 'package:venera_unified/foundation/image_translation/translation_pipeline.dart';
import 'package:venera_unified/foundation/image_translation/translation_types.dart';

OcrBlock _block(
  String text, {
  String language = 'ja',
  int left = 10,
}) {
  return OcrBlock(
    rect: IntRect(left, 20, left + 100, 60),
    text: text,
    language: language,
    backgroundColor: 0xffffffff,
    textColor: 0xff000000,
  );
}

void main() {
  group('sameLanguageAction', () {
    test('foreign blocks always translate', () {
      expect(sameLanguageAction('ja', 'zh'), SameLanguageAction.translate);
      expect(sameLanguageAction('ko', 'zh'), SameLanguageAction.translate);
      expect(sameLanguageAction('en', 'zh'), SameLanguageAction.translate);
    });

    test('identical language skips', () {
      expect(sameLanguageAction('ja', 'ja'), SameLanguageAction.skip);
      expect(sameLanguageAction('en', 'en'), SameLanguageAction.skip);
      expect(
        sameLanguageAction('zh-TW', 'zh-TW'),
        SameLanguageAction.skip,
      );
    });

    test('simplified into traditional converts without the model', () {
      expect(
        sameLanguageAction('zh', 'zh-TW'),
        SameLanguageAction.toTraditional,
      );
    });

    test('traditional into simplified still goes to the model', () {
      expect(
        sameLanguageAction('zh-TW', 'zh'),
        SameLanguageAction.translate,
      );
    });
  });

  group('PageTranslationPipeline.regionsFromTranslation', () {
    final pipeline = PageTranslationPipeline();

    test('pairs pending blocks with aligned texts', () {
      final pending = [_block('hello'), _block('world', left: 200)];
      final regions = pipeline.regionsFromTranslation(pending, ['A', 'B']);
      expect(regions.map((r) => r.text), ['A', 'B']);
      expect(regions.first.rect.left, 10);
      expect(regions.first.backgroundColor, 0xffffffff);
      expect(regions.first.eraseRects, isNotEmpty);
    });

    test('drops empty and unchanged translations', () {
      final pending = [_block('a'), _block('b'), _block('c')];
      final regions = pipeline.regionsFromTranslation(pending, ['', 'b', 'C']);
      expect(regions.map((r) => r.text), ['C']);
    });

    test('missing texts count as empty, extras are ignored', () {
      final pending = [_block('a'), _block('b')];
      expect(pipeline.regionsFromTranslation(pending, ['A']), hasLength(1));
      expect(
        pipeline.regionsFromTranslation(pending, ['A', 'B', 'zzz']),
        hasLength(2),
      );
      expect(pipeline.regionsFromTranslation(pending, const []), isEmpty);
    });

    test('trims whitespace-only translations away', () {
      final regions = pipeline.regionsFromTranslation([_block('a')], ['   ']);
      expect(regions, isEmpty);
    });
  });

  group('PageAnalysis and PageOcr', () {
    test('PageOcr.isEmpty reflects both lists', () {
      expect(PageOcr(const [], const [], const {}).isEmpty, isTrue);
      expect(
        PageOcr([_block('a').letRegion()], const [], const {}).isEmpty,
        isFalse,
      );
      expect(
        PageOcr(const [], [_block('a')], const {}).isEmpty,
        isFalse,
      );
    });

    test('PageAnalysis carries votes and glossary', () {
      final analysis = PageAnalysis(
        [_block('a').letRegion()],
        {'ja': 2},
        {'name': '名'},
      );
      expect(analysis.regions.single.text, 'a');
      expect(analysis.languageVotes, {'ja': 2});
      expect(analysis.newGlossary, {'name': '名'});
      expect(PageAnalysis(const [], const {}).newGlossary, isEmpty);
    });
  });

  group('pipeline misc', () {
    test('constructs and reports a boolean warm state', () {
      final pipeline = PageTranslationPipeline();
      expect(pipeline.ocrIsWarm, isA<bool>());
    });

    test('logTranslationFailure never throws', () {
      expect(
        () => logTranslationFailure(
          Exception('boom'),
          StackTrace.current,
        ),
        returnsNormally,
      );
    });
  });

  group('OpenCC traditional vote (pipeline language detection)', () {
    // '发/开' are simplified-only, '發/開' traditional-only under this table.
    final table = OpenCCTable.parse('发發\n开開\n');
    test('majority traditional reads as traditional', () {
      expect(table.isMostlyTraditional('發發發发'), isTrue);
    });

    test('majority simplified reads as simplified', () {
      expect(table.isMostlyTraditional('发发發'), isFalse);
    });

    test('ties and empty text read as simplified', () {
      expect(table.isMostlyTraditional('發发'), isFalse);
      expect(table.isMostlyTraditional(''), isFalse);
      expect(table.isMostlyTraditional('hello'), isFalse);
    });
  });
}

extension on OcrBlock {
  TranslatedRegion letRegion() => TranslatedRegion(
        rect: rect,
        eraseRect: eraseRect,
        eraseRects: eraseRects,
        text: text,
        backgroundColor: backgroundColor,
        textColor: textColor,
        lineHeight: lineHeight,
      );
}
