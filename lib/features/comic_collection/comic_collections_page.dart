import 'package:flutter/material.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/components/input_dialog.dart';
import 'package:venera_unified/components/menu.dart';
import 'package:venera_unified/components/message.dart';
import 'package:venera_unified/components/scroll.dart';
import 'package:venera_unified/features/comic_collection/collection_source.dart';
import 'package:venera_unified/features/comic_collection/comic_collection_edit_page.dart';
import 'package:venera_unified/features/comic_collection/comic_collection_store.dart';
import 'package:venera_unified/features/comic_details/comic_details.dart';
import 'package:venera_unified/features/comic_source/comic_source.dart';
import 'package:venera_unified/features/comic_widgets/comic_widgets.dart';
import 'package:venera_unified/features/favorites/favorites.dart';
import 'package:venera_unified/features/history/history_manager.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/comic_type.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/file_system.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';
import 'package:venera_unified/routing/app_navigation.dart';

/// Deletes a collection and the traces it leaves behind.
///
/// Removing only the configuration would leave its favourite row and reading
/// history pointing at a source that no longer resolves — the row would still
/// render but open to an error, with no way to clear it from the favourites
/// screen (its "delete" acts on the comic, which is exactly what's gone).
/// Member comics and their own history are untouched.
///
/// Unified alignment: every manager mutation here is async, and the read-later
/// entry needs no separate call — read-later is a folder inside the favorites
/// database, so the folder loop below already removes it.
Future<void> deleteComicCollection(ComicCollection collection) async {
  final type = ComicType.fromKey(collection.sourceKey);
  for (final folder in LocalFavoritesManager().find(collection.id, type)) {
    await LocalFavoritesManager().deleteComicWithId(
      folder,
      collection.id,
      type,
    );
  }
  await HistoryManager().remove(collection.id, type);
  // A cover picked from a file lives in our own data directory, so deleting the
  // collection has to take it along or it stays there for good.
  try {
    final dir = Directory(
      FilePath.join(App.dataPath, ComicCollectionStore.coverDirName),
    );
    if (dir.existsSync()) {
      for (final e in dir.listSync()) {
        if (e is File && e.name.startsWith('${collection.id}_')) {
          await e.deleteIgnoreError();
        }
      }
    }
  } catch (e) {
    // A leftover cover file is not worth failing the delete over.
    Log.error('ComicCollection', 'Cover cleanup failed: $e');
  }
  ComicCollectionStore.remove(collection.id);
}

/// Filters collections by name or member label. Pure: unit-tested.
List<ComicCollection> filterCollections(
  List<ComicCollection> collections,
  String keyword,
) {
  final query = keyword.trim().toLowerCase();
  return collections.where((collection) {
    if (query.isEmpty) return true;
    return collection.displayName.toLowerCase().contains(query) ||
        collection.members.any(
          (member) => member.label.toLowerCase().contains(query),
        );
  }).toList();
}

/// Sorts collections in place by the list page's sort mode. Pure: unit-tested.
void sortCollections(List<ComicCollection> collections, String sortMode) {
  switch (sortMode) {
    case 'name':
      collections.sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
      break;
    case 'count':
      collections.sort((a, b) => b.members.length.compareTo(a.members.length));
      break;
    case 'created':
      collections.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      break;
  }
}

/// Lists the user's comic collections: open one as a comic, edit its members,
/// reorder or delete it.
///
/// A collection groups comics that belong to one story but were published (or
/// scraped) as separate entries — volumes, parts, seasons — so they can be read
/// as one comic with one chapter list.
///
/// Ported from VeneraX `lib/pages/comic_collections_page.dart`. Unified
/// alignments: hand-rolled multi-select (no SelectionMixin), a plain TextField
/// search box (no AppSearchField), no guide entries (no GuidePage), async
/// manager mutations, and the grid's own blocked-comic filter.
class ComicCollectionsPage extends StatefulWidget {
  const ComicCollectionsPage({super.key});

  @override
  State<ComicCollectionsPage> createState() => _ComicCollectionsPageState();
}

class _ComicCollectionsPageState extends State<ComicCollectionsPage> {
  List<ComicCollection> collections = const [];
  final searchTextController = TextEditingController();
  var keyword = '';
  var sortMode = 'manual';
  var multiSelectMode = false;
  var selectedItems = <Comic, bool>{};

  @override
  void initState() {
    super.initState();
    _reload();
    // Picks up edits made elsewhere (the detail page's tab menu, a member cache
    // filled by a background load, a sync download).
    ComicCollectionStore.changes.addListener(_reload);
  }

  @override
  void dispose() {
    ComicCollectionStore.changes.removeListener(_reload);
    searchTextController.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      collections = ComicCollectionStore.all();
      _pruneSelection();
      if (collections.isEmpty) multiSelectMode = false;
    });
  }

  void _pruneSelection() {
    final visible = selectableItems.toSet();
    selectedItems.removeWhere((comic, _) => !visible.contains(comic));
  }

  void _enterSelectMode(Comic comic) {
    setState(() {
      multiSelectMode = true;
      selectedItems = {comic: true};
    });
  }

  void selectAll() {
    setState(() {
      selectedItems = {for (final c in selectableItems) c: true};
    });
  }

  void deSelect() {
    setState(() {
      selectedItems.clear();
    });
  }

  void invertSelection() {
    setState(() {
      final visible = selectableItems;
      selectedItems = {
        for (final c in visible)
          if (!selectedItems.containsKey(c)) c: true,
      };
    });
  }

  void toggleSelect(Comic comic) {
    setState(() {
      if (selectedItems.containsKey(comic)) {
        selectedItems.remove(comic);
      } else {
        selectedItems[comic] = true;
      }
    });
  }

  void exitSelectMode() {
    setState(() {
      multiSelectMode = false;
      selectedItems.clear();
    });
  }

  /// Re-registers the native sources after any change: the built source captures
  /// the collection's layout, so a stale one would keep serving the old chapter
  /// list (or linger after a delete).
  void _applyChange() {
    refreshCollectionSources();
    _reload();
  }

  void _open(ComicCollection collection) {
    appNavigation.mainNavigatorKey?.currentContext?.to(
      () => ComicPage(
        id: collection.id,
        sourceKey: collection.sourceKey,
        cover: collection.displayCover,
        title: collection.displayName,
      ),
    );
  }

  void _edit(ComicCollection collection) async {
    await context.to(
      () => ComicCollectionEditPage(collectionId: collection.id),
    );
    if (mounted) _applyChange();
  }

  void _create() {
    showInputDialog(
      context: context,
      title: "New collection".tl,
      hintText: "Collection name".tl,
      onConfirm: (value) {
        final name = value.trim();
        if (name.isEmpty) return "Please enter a name".tl;
        final collection = ComicCollectionStore.create(name: name);
        _applyChange();
        // Straight into the editor: an empty collection is useless, so the next
        // thing the user needs is the add-comics screen.
        _edit(collection);
        return null;
      },
    );
  }

  void _delete(ComicCollection collection) {
    showConfirmDialog(
      context: context,
      title: "Delete".tl,
      content: "Delete collection '@n'? The comics in it are kept.".tlParams({
        "n": collection.displayName,
      }),
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        await deleteComicCollection(collection);
        _applyChange();
      },
    );
  }

  List<ComicCollection> get filteredCollections {
    final result = filterCollections(collections, keyword);
    sortCollections(result, sortMode);
    return result;
  }

  List<Comic> get selectableItems => filteredCollections.map(_asComic).toList();

  List<ComicCollection> get selectedCollections => filteredCollections
      .where((collection) => selectedItems.containsKey(_asComic(collection)))
      .toList();

  void _deleteSelected() {
    final selected = selectedCollections;
    if (selected.isEmpty) return;
    showConfirmDialog(
      context: context,
      title: 'Delete'.tl,
      content: 'Delete @c collections? The comics in them are kept.'.tlParams({
        'c': selected.length,
      }),
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        for (final collection in selected) {
          await deleteComicCollection(collection);
        }
        exitSelectMode();
        _applyChange();
        if (mounted) {
          showToast(
            context: context,
            message: 'Deleted @c items'.tlParams({'c': selected.length}),
          );
        }
      },
    );
  }

  Future<void> _addSelectedToReadLater() async {
    final comics = selectedCollections.map(_asComic).toList();
    if (comics.isEmpty) return;
    try {
      for (final comic in comics) {
        await LocalFavoritesManager().setReadLater(
          _toFavoriteItem(comic),
          included: true,
          folderName: 'Read later'.tl,
        );
      }
      if (!mounted) return;
      exitSelectMode();
      context.showMessage(message: 'Added to read later'.tl);
    } catch (error, stackTrace) {
      Log.error('ComicCollection', error, stackTrace);
      if (mounted) context.showMessage(message: 'Error'.tl);
    }
  }

  FavoriteItem _toFavoriteItem(Comic comic) => FavoriteItem(
    id: comic.id,
    name: comic.title,
    coverPath: comic.cover,
    author: '',
    type: ComicType.fromKey(comic.sourceKey),
    tags: const [],
  );

  Comic _asComic(ComicCollection collection) => Comic(
    collection.displayName,
    collection.displayCover,
    collection.id,
    null,
    const ['Collection'],
    '@n comics'.tlParams({'n': collection.members.length}),
    collection.sourceKey,
    null,
    null,
  );

  String _sortLabel(String value) {
    switch (value) {
      case 'name':
        return 'Name'.tl;
      case 'count':
        return 'Comic count'.tl;
      case 'created':
        return 'Recently created'.tl;
      default:
        return 'Custom order'.tl;
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleComics = selectableItems;
    void handleBatchAction(String value) {
      switch (value) {
        case 'selectAll':
          selectAll();
          break;
        case 'deselect':
          deSelect();
          break;
        case 'invert':
          invertSelection();
          break;
        case 'delete':
          _deleteSelected();
          break;
        case 'favorite':
          final comics = selectedCollections.map(_asComic).toList();
          if (comics.isNotEmpty) addFavorite(context, comics);
          break;
        case 'readLater':
          _addSelectedToReadLater();
          break;
        case 'edit':
          final selected = selectedCollections;
          if (selected.length != 1) return;
          exitSelectMode();
          _edit(selected.single);
          break;
      }
    }

    final batchMenu = PopupMenuButton<String>(
      tooltip: 'Batch manage'.tl,
      icon: const Icon(Icons.more_vert),
      onSelected: handleBatchAction,
      itemBuilder: (context) => [
        PopupMenuItem(value: 'selectAll', child: Text('Select All'.tl)),
        PopupMenuItem(value: 'deselect', child: Text('Deselect'.tl)),
        PopupMenuItem(value: 'invert', child: Text('Invert Selection'.tl)),
        PopupMenuItem(
          value: 'delete',
          enabled: selectedItems.isNotEmpty,
          child: Text('Delete'.tl),
        ),
        PopupMenuItem(
          value: 'favorite',
          enabled: selectedItems.isNotEmpty,
          child: Text('Add to favorites'.tl),
        ),
        PopupMenuItem(
          value: 'readLater',
          enabled: selectedItems.isNotEmpty,
          child: Text('Read later'.tl),
        ),
        if (selectedItems.length == 1)
          PopupMenuItem(value: 'edit', child: Text('Edit'.tl)),
      ],
    );
    final selectActions = context.width < 520
        ? [batchMenu]
        : [
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: 'Select All'.tl,
              onPressed: selectAll,
            ),
            IconButton(
              icon: const Icon(Icons.flip),
              tooltip: 'Invert Selection'.tl,
              onPressed: invertSelection,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete'.tl,
              onPressed: selectedItems.isEmpty ? null : _deleteSelected,
            ),
            batchMenu,
          ];
    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && multiSelectMode) exitSelectMode();
      },
      child: Scaffold(
        appBar: Appbar(
          leading: Tooltip(
            message: multiSelectMode ? 'Cancel'.tl : 'Back'.tl,
            child: IconButton(
              icon: multiSelectMode
                  ? const Icon(Icons.close)
                  : const Icon(Icons.arrow_back),
              onPressed: multiSelectMode ? exitSelectMode : () => context.pop(),
            ),
          ),
          title: multiSelectMode
              ? Text(selectedItems.length.toString())
              : Text('Collections'.tl),
          actions: [
            if (multiSelectMode)
              ...selectActions
            else ...[
              IconButton(
                tooltip: 'Multi-Select'.tl,
                icon: const Icon(Icons.checklist),
                onPressed: visibleComics.isEmpty
                    ? null
                    : () => setState(() => multiSelectMode = true),
              ),
              PopupMenuButton<String>(
                tooltip: 'Sort'.tl,
                icon: const Icon(Icons.sort),
                initialValue: sortMode,
                onSelected: (value) => setState(() => sortMode = value),
                itemBuilder: (context) => [
                  for (final value in ['manual', 'name', 'count', 'created'])
                    PopupMenuItem(value: value, child: Text(_sortLabel(value))),
                ],
              ),
              Tooltip(
                message: 'New collection'.tl,
                child: IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _create,
                ),
              ),
            ],
          ],
        ),
        body: SmoothCustomScrollView(
          slivers: [
            if (collections.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    controller: searchTextController,
                    decoration: InputDecoration(
                      hintText: 'Search'.tl,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: keyword.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                searchTextController.clear();
                                setState(() {
                                  keyword = '';
                                  _pruneSelection();
                                });
                              },
                            ),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (value) => setState(() {
                      keyword = value;
                      _pruneSelection();
                    }),
                  ),
                ),
              ),
            if (collections.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildEmptyState(),
              )
            else if (visibleComics.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text('No matching collections'.tl, style: ts.s16),
                ),
              )
            else
              SliverGridComics(
                comics: visibleComics,
                selections: selectedItems,
                onLongPressed: multiSelectMode
                    ? (comic, heroID) => toggleSelect(comic)
                    : null,
                onTap: (comic, heroID) {
                  if (multiSelectMode) {
                    toggleSelect(comic);
                    return;
                  }
                  final collection = ComicCollectionStore.find(comic.id);
                  if (collection != null) _open(collection);
                },
                menuBuilder: (comic) {
                  final collection = ComicCollectionStore.find(comic.id);
                  if (collection == null) return const [];
                  final sourceIndex = collections.indexWhere(
                    (item) => item.id == collection.id,
                  );
                  return [
                    if (!multiSelectMode)
                      MenuEntry(
                        icon: Icons.checklist,
                        text: 'Multi-Select'.tl,
                        onClick: () => _enterSelectMode(comic),
                      ),
                    MenuEntry(
                      icon: Icons.edit,
                      text: 'Edit'.tl,
                      onClick: () => _edit(collection),
                    ),
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: 'Delete'.tl,
                      color: context.colorScheme.error,
                      onClick: () => _delete(collection),
                    ),
                    if (sourceIndex > 0)
                      MenuEntry(
                        icon: Icons.arrow_upward,
                        text: 'Move up'.tl,
                        onClick: () {
                          ComicCollectionStore.reorder(
                            sourceIndex,
                            sourceIndex - 1,
                          );
                          _applyChange();
                        },
                      ),
                    if (sourceIndex >= 0 &&
                        sourceIndex < collections.length - 1)
                      MenuEntry(
                        icon: Icons.arrow_downward,
                        text: 'Move down'.tl,
                        onClick: () {
                          ComicCollectionStore.reorder(
                            sourceIndex,
                            sourceIndex + 1,
                          );
                          _applyChange();
                        },
                      ),
                  ];
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_books_outlined,
              size: 64,
              color: context.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text("No collections yet".tl, style: ts.s16),
            const SizedBox(height: 8),
            Text(
              "Group the volumes of one story into a single comic. Long-press a comic in any list to add it."
                  .tl,
              style: ts.s14.copyWith(color: context.colorScheme.outline),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: Text("New collection".tl),
            ),
          ],
        ),
      ),
    );
  }
}
