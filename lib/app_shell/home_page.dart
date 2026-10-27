import 'package:venera_unified/features/favorites/favorites_scope.dart';
import 'package:venera_unified/features/history/history_scope.dart';
import 'package:flutter/material.dart';
import 'package:venera_unified/components/scroll.dart';
import 'package:venera_unified/features/comic_source/comic_source.dart';
import 'package:venera_unified/foundation/consts.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/features/history/history.dart';
import 'package:venera_unified/features/favorites/favorites.dart';
import 'package:venera_unified/features/local_comics/local_comics.dart';
import 'package:venera_unified/features/random/random_comic_entry.dart';
import 'package:venera_unified/features/follow_updates/follow_updates.dart';
import 'package:venera_unified/features/image_favorites/image_favorites.dart';
import 'package:venera_unified/features/search/search.dart';
import 'package:venera_unified/features/sync/sync.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    var widget = SmoothCustomScrollView(
      slivers: [
        SliverPadding(padding: EdgeInsets.only(top: context.padding.top)),
        const SearchEntry(),
        const SyncStatusSummary(),
        const RandomComicEntry(),
        HistorySummary(
          manager: HistoryScope.read(context),
          favoriteChanges: FavoritesScope.read(context),
        ),
        const ReadLaterSummary(),
        const LocalComicsSummary(),
        const FollowUpdatesWidget(),
        ComicSourceSummary(manager: ComicSourceManager.current),
        const ImageFavoritesSummary(),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
    return context.width > changePoint ? widget.paddingHorizontal(8) : widget;
  }
}
