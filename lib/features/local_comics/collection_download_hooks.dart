import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/foundation/res.dart';

/// Expansion of a collection's placeholder chapters into member chapters.
typedef CollectionChapterExpansion = ({
  ComicDetails comic,
  List<String>? chapters,
});

/// Download hooks implemented by the comic_collection feature.
///
/// The download task calls these instead of importing comic_collection: the
/// import edge would close a business-file cycle
/// (images_download_task → collection_source → local → codec → task) that the
/// architecture gate rejects. With hooks, the only edges are the one-way
/// comic_collection → local_comics and comic_collection → comic_source ones.
///
/// Unregistered (null) means the comic_collection feature is absent: the task
/// must behave exactly as if collections did not exist.
abstract interface class CollectionDownloadHooks {
  /// Whether [sourceKey] belongs to a comic collection.
  bool isCollectionSource(String sourceKey);

  /// Collection page list for downloading: skips the local `file://` shortcut
  /// and always resolves the network pages.
  Future<Res<List<String>>> loadPagesForDownload(String comicId, String? ep);

  /// Expands placeholder chapters (empty member chapter id) into the members'
  /// real chapters, rebuilding [comic] and the chapter filter to match.
  /// Returns the inputs unchanged when there is nothing to expand, and
  /// discards partial work when [isCancelled] fires.
  Future<CollectionChapterExpansion> resolveChapters({
    required ComicDetails comic,
    required List<String>? chapters,
    required bool Function() isCancelled,
  });
}

CollectionDownloadHooks? _hooks;

/// Registers the collection download hooks. Null restores the direct-source
/// behavior; the download task must work identically with no hooks registered.
void configureCollectionDownloadHooks(CollectionDownloadHooks? hooks) {
  _hooks = hooks;
}

/// The registered hooks, or null when the comic_collection feature is absent.
CollectionDownloadHooks? get collectionDownloadHooks => _hooks;
