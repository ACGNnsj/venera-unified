import 'package:venera_unified/features/history/history.dart';
import 'package:venera_unified/features/local_comics/local_comics.dart';
import 'package:venera_unified/features/reader/reader.dart';
import 'package:venera_unified/routing/app_navigation.dart';
import 'package:venera_unified/foundation/context.dart';

void openLocalComic(LocalComic comic) {
  final history = HistoryManager().find(comic.id, comic.comicType);
  final start = resolveLocalReadingStart(
    chapters: comic.chapters,
    downloadedChapters: comic.downloadedChapters,
    historyChapter: history?.ep,
    historyPage: history?.page,
    historyGroup: history?.group,
  );
  appNavigation.rootContext.to(
    () => Reader(
      onClosed: ReaderSessionScope.onClosedOf(appNavigation.rootContext),
      type: comic.comicType,
      cid: comic.id,
      name: comic.title,
      chapters: comic.chapters,
      initialChapter: start.chapter,
      initialPage: start.page,
      initialChapterGroup: start.group,
      history: history ?? History.fromModel(model: comic, ep: 0, page: 0),
      author: comic.subtitle,
      tags: comic.tags,
    ),
  );
}
