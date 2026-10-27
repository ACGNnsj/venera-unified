import 'package:flutter/services.dart';

/// 桌面端翻页快捷键要做的事。
enum ReaderKeyAction {
  firstPage,
  lastPage,
  nextPage,
  previousPage,
  nextChapter,
  previousChapter,
}

/// 把按键翻译成翻页动作；返回 null 表示这键不该由阅读器接管。
///
/// 这里是纯函数，不碰页面状态，方便单测；真正的执行在 `reader_page.dart`。
/// 位置都是 0 基：`page` 从 0 到 `maxPage - 1`。
ReaderKeyAction? readerKeyAction(
  LogicalKeyboardKey key, {
  required int page,
  required int maxPage,
  required bool isFirstChapterOfGroup,
  required bool isLastChapterOfGroup,
}) {
  if (key == LogicalKeyboardKey.home) {
    return ReaderKeyAction.firstPage;
  }
  if (key == LogicalKeyboardKey.end) {
    return maxPage > 0 ? ReaderKeyAction.lastPage : null;
  }
  if (key == LogicalKeyboardKey.pageDown) {
    if (page + 1 < maxPage) return ReaderKeyAction.nextPage;
    if (!isLastChapterOfGroup) return ReaderKeyAction.nextChapter;
    return null;
  }
  if (key == LogicalKeyboardKey.pageUp) {
    if (page > 0) return ReaderKeyAction.previousPage;
    if (!isFirstChapterOfGroup) return ReaderKeyAction.previousChapter;
    return null;
  }
  return null;
}
