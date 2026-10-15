import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/history_model.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

History history() => History.fromMap({
  'type': 0,
  'time': 1000,
  'title': 'Book',
  'subtitle': '',
  'cover': '',
  'id': 'book',
  'ep': 21,
  'page': 162,
  'max_chapter': 55,
  'max_page': 233,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  setUp(() {
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = language);
  });

  test('default description keeps legacy coordinates and saved names', () {
    final item = history();
    expect(item.description, 'Chapter 21 - Page 162');
    item
      ..group = 2
      ..groupTitle = ' Volume Two '
      ..chapterTitle = ' A new beginning ';
    expect(item.description, 'Volume Two - A new beginning - Page 162');
    expect(
      item.progressDescription(showTotals: true),
      'Volume Two - Chapter 21 / 55 - Page 162 / 233',
    );
    expect(
      item.progressDescription(showTotals: true, compact: true),
      'Ch. 21/55\nP. 162/233',
    );
    expect(item.copy().maxChapter, 55);
  });

  for (final (language, full, compact) in [
    ('en-US', 'Chapter 21 / 55 - Page 162 / 233', 'Ch. 21/55\nP. 162/233'),
    ('zh-CN', '第 21 / 55 章 - 第 162 / 233 页', '21/55 章\n162/233 页'),
    ('zh-TW', '第 21 / 55 章 - 第 162 / 233 頁', '21/55 章\n162/233 頁'),
  ]) {
    test('full and compact progress translate in $language', () {
      appdata.settings['language'] = language;
      expect(history().progressDescription(showTotals: true), full);
      expect(
        history().progressDescription(showTotals: true, compact: true),
        compact,
      );
    });
  }

  test(
    'legacy histories show known page totals without inventing chapters',
    () {
      final item = History.fromMap({
        'type': 0,
        'time': 1000,
        'title': 'Book',
        'subtitle': '',
        'cover': '',
        'id': 'book',
        'ep': 21,
        'page': 162,
        'max_page': 233,
      });
      expect(item.maxChapter, isNull);
      expect(
        item.progressDescription(showTotals: true),
        'Chapter 21 - Page 162 / 233',
      );
      item.maxPage = null;
      expect(item.progressDescription(showTotals: true), item.description);
    },
  );

  test(
    'nonpositive and inconsistent snapshots do not produce false ratios',
    () {
      for (final total in [null, -1, 0, 20]) {
        final item = history()
          ..maxChapter = total
          ..maxPage = total;
        expect(
          item.progressDescription(showTotals: true),
          'Chapter 21 - Page 162',
        );
      }
      final item = history()
        ..ep = 55
        ..page = 233;
      expect(
        item.progressDescription(showTotals: true),
        'Chapter 55 / 55 - Page 233 / 233',
      );
    },
  );

  test('unknown coordinates and empty content omit their labels', () {
    final item = history()..ep = 0;
    expect(item.progressDescription(showTotals: true), 'Page 162 / 233');
    item.page = 0;
    expect(item.progressDescription(showTotals: true), isEmpty);
    expect(item.progressDescription(showTotals: true, compact: true), isEmpty);
  });
}
