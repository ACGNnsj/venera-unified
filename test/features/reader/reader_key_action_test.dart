import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/reader/reader_key_action.dart';

ReaderKeyAction? act(
  LogicalKeyboardKey key, {
  int page = 0,
  int maxPage = 5,
  bool firstOfGroup = false,
  bool lastOfGroup = false,
}) => readerKeyAction(
  key,
  page: page,
  maxPage: maxPage,
  isFirstChapterOfGroup: firstOfGroup,
  isLastChapterOfGroup: lastOfGroup,
);

void main() {
  test('Home 与 End 跳到首末页', () {
    expect(act(LogicalKeyboardKey.home, page: 3), ReaderKeyAction.firstPage);
    expect(act(LogicalKeyboardKey.end, page: 1), ReaderKeyAction.lastPage);
    expect(act(LogicalKeyboardKey.end, maxPage: 0), isNull);
  });

  test('PageDown/PageUp 优先翻页', () {
    expect(act(LogicalKeyboardKey.pageDown, page: 1), ReaderKeyAction.nextPage);
    expect(
      act(LogicalKeyboardKey.pageUp, page: 1),
      ReaderKeyAction.previousPage,
    );
  });

  test('翻到底/顶时落到相邻章节，章节边界则放行', () {
    expect(
      act(LogicalKeyboardKey.pageDown, page: 4),
      ReaderKeyAction.nextChapter,
    );
    expect(
      act(LogicalKeyboardKey.pageUp, page: 0),
      ReaderKeyAction.previousChapter,
    );
    expect(
      act(LogicalKeyboardKey.pageDown, page: 4, lastOfGroup: true),
      isNull,
    );
    expect(act(LogicalKeyboardKey.pageUp, page: 0, firstOfGroup: true), isNull);
  });

  test('其它键不接管', () {
    expect(act(LogicalKeyboardKey.keyB), isNull);
    expect(act(LogicalKeyboardKey.arrowRight), isNull);
  });
}
