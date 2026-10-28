import 'package:venera_unified/features/favorites/favorites_scope.dart';
import 'package:venera_unified/features/history/history_scope.dart';
import 'package:flutter/material.dart';
import 'package:venera_unified/components/scroll.dart';
import 'package:venera_unified/features/comic_source/comic_source.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/consts.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/home_layout.dart';
import 'package:venera_unified/features/history/history.dart';
import 'package:venera_unified/features/favorites/favorites.dart';
import 'package:venera_unified/features/local_comics/local_comics.dart';
import 'package:venera_unified/features/random/random_comic_entry.dart';
import 'package:venera_unified/features/follow_updates/follow_updates.dart';
import 'package:venera_unified/features/image_favorites/image_favorites.dart';
import 'package:venera_unified/features/search/search.dart';
import 'package:venera_unified/features/sync/sync.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late List<HomeSectionConfig> layout = normalizeHomeLayout();

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    // Re-read the layout when settings change (e.g. edited from the Home Page
    // Layout settings page, or a new layout arrived via WebDAV sync download).
    var next = normalizeHomeLayout();
    if (!_sameLayout(next, layout) && mounted) {
      setState(() => layout = next);
    }
  }

  static bool _sameLayout(
    List<HomeSectionConfig> a,
    List<HomeSectionConfig> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].visible != b[i].visible) return false;
    }
    return true;
  }

  /// Maps a section id to its sliver. Each gets a [ValueKey] so reordering
  /// preserves the per-section [State]. Must stay in sync with
  /// [kHomeSections].
  Widget _sectionWidget(String id) {
    return switch (id) {
      'search' => const SearchEntry(key: ValueKey('search')),
      'sync' => const SyncStatusSummary(key: ValueKey('sync')),
      'random' => const RandomComicEntry(key: ValueKey('random')),
      'history' => HistorySummary(
        key: const ValueKey('history'),
        manager: HistoryScope.read(context),
        favoriteChanges: FavoritesScope.read(context),
      ),
      'readLater' => const ReadLaterSummary(key: ValueKey('readLater')),
      'local' => const LocalComicsSummary(key: ValueKey('local')),
      'followUpdates' => const FollowUpdatesWidget(
        key: ValueKey('followUpdates'),
      ),
      'comicSource' => ComicSourceSummary(
        key: const ValueKey('comicSource'),
        manager: ComicSourceManager.current,
      ),
      'imageFavorites' => const ImageFavoritesSummary(
        key: ValueKey('imageFavorites'),
      ),
      _ => const SliverToBoxAdapter(child: SizedBox.shrink()),
    };
  }

  @override
  Widget build(BuildContext context) {
    var widget = SmoothCustomScrollView(
      slivers: [
        SliverPadding(padding: EdgeInsets.only(top: context.padding.top)),
        for (var config in layout)
          if (config.visible) _sectionWidget(config.id),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
    return context.width > changePoint ? widget.paddingHorizontal(8) : widget;
  }
}
