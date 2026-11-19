import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/components/gesture.dart';
import 'package:venera_unified/components/layout.dart';
import 'package:venera_unified/components/settings_save_state.dart';
import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/features/history/history_api.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:venera_unified/foundation/global_preference_store.dart';
import 'package:venera_unified/foundation/opencc.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';
import 'chapter_order.dart';

class ComicChaptersView extends StatefulWidget {
  const ComicChaptersView({
    super.key,
    required this.chapters,
    this.history,
    required this.readChapter,
    this.collectionId,
    this.onCollectionTabAction,
  });

  final ComicChapters chapters;

  final History? history;

  final void Function(int chapter) readChapter;

  /// Set when this detail page shows a user-assembled collection. Each tab is
  /// then one member comic, so tabs become editable.
  final String? collectionId;

  /// Opens the tab menu for [collectionId] at the given tab and position.
  final Future<void> Function(int tabIndex, Offset position)?
  onCollectionTabAction;

  @override
  State<ComicChaptersView> createState() => _ComicChaptersViewState();
}

class _ComicChaptersViewState extends SettingsSaveState<ComicChaptersView> {
  String? _previewOrder;
  bool? _previewHide;
  int _request = 0;

  GlobalPreferenceStore get _prefs => GlobalPreferenceStore(appdata.settings);

  ChapterOrder get order => ChapterOrder.resolve(
    _previewOrder ?? _prefs.read(AppPreferences.chapterOrder),
    legacyReverse: _prefs.read(AppPreferences.reverseChapterOrder),
  );

  bool get hideDuplicates =>
      _previewHide ?? _prefs.read(AppPreferences.hideDuplicateChapters);

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _setOrder(ChapterOrder value) {
    if (!acceptsSettingsChanges || value == order) return;
    final request = ++_request;
    setState(() => _previewOrder = value.name);
    saveSetting(
      AppPreferences.chapterOrder.key,
      () => appdata.updateSettings((draft) {
        final store = GlobalPreferenceStore(draft);
        store.write(AppPreferences.chapterOrder, value.name);
        store.write(
          AppPreferences.reverseChapterOrder,
          value == ChapterOrder.reverse,
        );
      }),
      onSaved: () {
        if (request == _request) setState(() => _previewOrder = null);
      },
    );
  }

  void _setHide(bool value) {
    if (!acceptsSettingsChanges || value == hideDuplicates) return;
    final request = ++_request;
    setState(() => _previewHide = value);
    saveSetting(
      AppPreferences.hideDuplicateChapters.key,
      () => appdata.updateSettings((draft) {
        GlobalPreferenceStore(
          draft,
        ).write(AppPreferences.hideDuplicateChapters, value);
      }),
      onSaved: () {
        if (request == _request) setState(() => _previewHide = null);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final orderControl = protectSettings(
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          settingsSaveStatus,
          _ChapterOrderMenu(
            order: order,
            hideDuplicates: hideDuplicates,
            onOrder: _setOrder,
            onHide: _setHide,
          ),
        ],
      ),
    );
    return widget.chapters.isGrouped
        ? _GroupedComicChapters(
            chapters: widget.chapters,
            history: widget.history,
            readChapter: widget.readChapter,
            order: order,
            hideDuplicates: hideDuplicates,
            orderControl: orderControl,
            collectionId: widget.collectionId,
            onCollectionTabAction: widget.onCollectionTabAction,
          )
        : _NormalComicChapters(
            chapters: widget.chapters,
            history: widget.history,
            readChapter: widget.readChapter,
            order: order,
            hideDuplicates: hideDuplicates,
            orderControl: orderControl,
          );
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_refresh);
    super.dispose();
  }
}

class _NormalComicChapters extends StatefulWidget {
  const _NormalComicChapters({
    required this.chapters,
    this.history,
    required this.readChapter,
    required this.order,
    required this.hideDuplicates,
    required this.orderControl,
  });

  final ComicChapters chapters;
  final ChapterOrder order;
  final bool hideDuplicates;
  final Widget orderControl;

  final History? history;

  final void Function(int chapter) readChapter;

  @override
  State<_NormalComicChapters> createState() => _NormalComicChaptersState();
}

class _NormalComicChaptersState extends State<_NormalComicChapters> {
  bool showAll = false;

  late History? history;

  @override
  void initState() {
    super.initState();
    history = widget.history;
  }

  @override
  void didUpdateWidget(covariant _NormalComicChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    setState(() {
      history = widget.history;
    });
  }

  @override
  Widget build(BuildContext context) {
    final chapters = widget.chapters;
    return SliverLayoutBuilder(
      builder: (context, constrains) {
        final display = ChapterVisibility.display(
          order: widget.order,
          ids: [
            for (var k = 0; k < chapters.length; k++) chapters.ids.elementAt(k),
          ],
          titles: [
            for (var k = 0; k < chapters.length; k++)
              chapters[chapters.ids.elementAt(k)]!,
          ],
          hideDuplicates: widget.hideDuplicates,
        );
        int length = display.length;
        bool canShowAll = showAll;
        if (!showAll) {
          var width = constrains.crossAxisExtent - 16;
          var crossItems = width ~/ 200;
          if (width % 200 != 0) {
            crossItems += 1;
          }
          length = math.min(length, crossItems * 8);
          if (length == display.length) {
            canShowAll = true;
          }
        }

        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      "Chapters".tl,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    widget.orderControl,
                  ],
                ),
              ),
            ),
            SliverGrid(
              delegate: SliverChildBuilderDelegate((context, i) {
                final actual = display[i];
                var key = chapters.ids.elementAt(actual);
                var value = chapters[key]!;
                bool visited =
                    history?.readEpisode.contains((actual + 1).toString()) ??
                    false;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                  child: Material(
                    color: context.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                    child: ClickInkWell(
                      onTap: () => widget.readChapter(actual + 1),
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Center(
                          child: Text(
                            value.displayText,
                            maxLines: 1,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: visited
                                  ? context.colorScheme.outline
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }, childCount: length),
              gridDelegate: const SliverGridDelegateWithFixedHeight(
                maxCrossAxisExtent: 250,
                itemHeight: 48,
              ),
            ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8)),
            if (!canShowAll)
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () {
                      setState(() {
                        showAll = true;
                      });
                    },
                    label: Text("${"Show all".tl} (${display.length})"),
                  ).paddingTop(12),
                ),
              ),
            const SliverToBoxAdapter(child: Divider()),
          ],
        );
      },
    );
  }
}

class _GroupedComicChapters extends StatefulWidget {
  const _GroupedComicChapters({
    required this.chapters,
    this.history,
    required this.readChapter,
    required this.order,
    required this.hideDuplicates,
    required this.orderControl,
    this.collectionId,
    this.onCollectionTabAction,
  });

  final ComicChapters chapters;
  final ChapterOrder order;
  final bool hideDuplicates;
  final Widget orderControl;

  final History? history;

  final void Function(int chapter) readChapter;

  final String? collectionId;

  final Future<void> Function(int tabIndex, Offset position)?
  onCollectionTabAction;

  @override
  State<_GroupedComicChapters> createState() => _GroupedComicChaptersState();
}

class _GroupedComicChaptersState extends State<_GroupedComicChapters>
    with TickerProviderStateMixin {
  bool showAll = false;

  late History? history;

  late TabController tabController;

  late int index;
  late List<String> _groups;

  @override
  void initState() {
    super.initState();
    history = widget.history;
    _groups = widget.chapters.groups.toList();
    index = ((history?.group ?? 1) - 1).clamp(
      0,
      math.max(0, _groups.length - 1),
    );
    _createTabs();
  }

  void _createTabs() {
    tabController = TabController(
      initialIndex: index,
      length: _groups.length,
      vsync: this,
    );
    tabController.addListener(onTabChange);
  }

  void onTabChange() {
    if (index != tabController.index) {
      setState(() {
        index = tabController.index;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _GroupedComicChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    final groups = widget.chapters.groups.toList();
    final previousGroup = _groups.elementAtOrNull(index);
    history = widget.history;
    if (!listEquals(groups, _groups)) {
      tabController.removeListener(onTabChange);
      tabController.dispose();
      _groups = groups;
      index = math.max(0, groups.indexOf(previousGroup ?? ''));
      showAll = false;
      _createTabs();
    }
  }

  @override
  void dispose() {
    tabController.removeListener(onTabChange);
    tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapters = widget.chapters;
    final groupNames = chapters.groups.toList();
    return SliverLayoutBuilder(
      builder: (context, constrains) {
        var group = _groups.isEmpty
            ? const <String, String>{}
            : chapters.getGroupByIndex(index);
        final groupIds = group.keys.toList();
        final display = ChapterVisibility.display(
          order: widget.order,
          ids: groupIds,
          titles: [for (final id in groupIds) group[id]!],
          hideDuplicates: widget.hideDuplicates,
        );
        int length = display.length;
        bool canShowAll = showAll;
        if (!showAll) {
          var width = constrains.crossAxisExtent - 16;
          var crossItems = width ~/ 200;
          if (width % 200 != 0) {
            crossItems += 1;
          }
          length = math.min(length, crossItems * 8);
          if (length == display.length) {
            canShowAll = true;
          }
        }

        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      "Chapters".tl,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    widget.orderControl,
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: AppTabBar(
                withUnderLine: false,
                controller: tabController,
                tabs: [
                  for (var i = 0; i < groupNames.length; i++)
                    Tab(
                      child:
                          widget.collectionId == null ||
                              widget.onCollectionTabAction == null
                          ? Text(groupNames[i].displayText)
                          // For a collection each tab IS a member comic, so the
                          // tab is where renaming and reordering it belongs.
                          : GestureDetector(
                              onLongPress: () => widget.onCollectionTabAction!(
                                i,
                                Offset(
                                  context.width / 2,
                                  context.padding.top + 120,
                                ),
                              ),
                              onSecondaryTapDown: (details) =>
                                  widget.onCollectionTabAction!(
                                    i,
                                    details.globalPosition,
                                  ),
                              child: Text(groupNames[i].displayText),
                            ),
                    ),
                ],
              ),
            ),
            SliverPadding(padding: const EdgeInsets.only(top: 8)),
            SliverGrid(
              delegate: SliverChildBuilderDelegate((context, i) {
                final actual = display[i];
                var key = groupIds[actual];
                var value = group[key]!;
                var chapterIndex = 0;
                for (var j = 0; j < chapters.groupCount; j++) {
                  if (j == index) {
                    chapterIndex += actual;
                    break;
                  }
                  chapterIndex += chapters.getGroupByIndex(j).length;
                }
                String rawIndex = (chapterIndex + 1).toString();
                String groupedIndex = "${index + 1}-${actual + 1}";
                bool visited = false;
                if (history != null) {
                  visited =
                      history!.readEpisode.contains(groupedIndex) ||
                      history!.readEpisode.contains(rawIndex);
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                  child: Material(
                    color: context.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    child: ClickInkWell(
                      onTap: () => widget.readChapter(chapterIndex + 1),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Center(
                          child: Text(
                            value.displayText,
                            maxLines: 1,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: visited
                                  ? context.colorScheme.outline
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }, childCount: length),
              gridDelegate: const SliverGridDelegateWithFixedHeight(
                maxCrossAxisExtent: 250,
                itemHeight: 48,
              ),
            ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8)),
            if (!canShowAll)
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () {
                      setState(() {
                        showAll = true;
                      });
                    },
                    label: Text("${"Show all".tl} (${display.length})"),
                  ).paddingTop(12),
                ),
              ),
            const SliverToBoxAdapter(child: Divider()),
          ],
        );
      },
    );
  }
}

class _ChapterOrderMenu extends StatelessWidget {
  const _ChapterOrderMenu({
    required this.order,
    required this.hideDuplicates,
    required this.onOrder,
    required this.onHide,
  });

  final ChapterOrder order;
  final bool hideDuplicates;
  final ValueChanged<ChapterOrder> onOrder;
  final ValueChanged<bool> onHide;

  static String label(ChapterOrder value) {
    switch (value) {
      case ChapterOrder.source:
        return "Source order".tl;
      case ChapterOrder.reverse:
        return "Reversed source order".tl;
      case ChapterOrder.titleAscending:
        return "Chapter title ascending".tl;
      case ChapterOrder.titleDescending:
        return "Chapter title descending".tl;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: "Hide duplicate chapters".tl,
          child: IconButton(
            visualDensity: VisualDensity.compact,
            isSelected: hideDuplicates,
            icon: const Icon(Icons.filter_alt_outlined),
            selectedIcon: const Icon(Icons.filter_alt),
            onPressed: () => onHide(!hideDuplicates),
          ),
        ),
        PopupMenuButton<ChapterOrder>(
          tooltip: "Order".tl,
          icon: const Icon(Icons.sort),
          initialValue: order,
          onSelected: onOrder,
          itemBuilder: (_) => [
            for (final o in ChapterOrder.values)
              CheckedPopupMenuItem(
                value: o,
                checked: o == order,
                child: Text(label(o)),
              ),
          ],
        ),
      ],
    );
  }
}
