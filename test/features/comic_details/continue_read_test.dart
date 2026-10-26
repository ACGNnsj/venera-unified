import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_details/actions.dart';
import 'package:venera_unified/features/history/history_api.dart';

void main() {
  test('continue reading without history uses the first chapter and page', () {
    final actions = _Actions(null)..continueRead();
    expect(actions.target, (chapter: 1, page: 1, group: null));
  });

  for (final page in [2, 1001]) {
    test('continue reading preserves an absent group at page $page', () {
      final history = _history(chapter: 1, page: page);
      final actions = _Actions(history)..continueRead();
      expect(actions.target, (chapter: 1, page: page, group: null));
      expect(history.group, isNull);
      expect(history.page, page);
    });
  }

  test('continue reading preserves legacy flattened chapter coordinates', () {
    final actions = _Actions(_history(chapter: 21, page: 162))..continueRead();
    expect(actions.target, (chapter: 21, page: 162, group: null));
  });

  test('continue reading preserves group-relative chapter coordinates', () {
    final actions = _Actions(_history(chapter: 2, page: 3, group: 4))
      ..continueRead();
    expect(actions.target, (chapter: 2, page: 3, group: 4));
  });
}

History _history({required int chapter, required int page, int? group}) =>
    History.fromMap({
      'id': 'book',
      'type': 0,
      'time': 1000,
      'title': 'Book',
      'subtitle': '',
      'cover': '',
      'ep': chapter,
      'page': page,
      'chapter_group': group,
    });

class _Actions extends Fake with ComicPageActions {
  _Actions(this.history);

  @override
  final History? history;

  ({int? chapter, int? page, int? group})? target;

  @override
  void read([int? ep, int? page, int? group]) {
    target = (chapter: ep, page: page, group: group);
  }
}
