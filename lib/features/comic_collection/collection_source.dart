import 'dart:async';

import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/features/local_comics/collection_download_hooks.dart';
import 'package:venera_unified/features/local_comics/local.dart';
import 'package:venera_unified/foundation/comic_type.dart';
import 'package:venera_unified/foundation/extensions.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:venera_unified/foundation/res.dart';
import 'package:venera_unified/foundation/translations.dart';

import 'comic_collection_chapter_id.dart';
import 'comic_collection_store.dart';

/// Builds the native (Dart, non-JS) [ComicSource] that presents one user-made
/// comic collection as a single comic.
///
/// Being a real [ComicSource] is what makes the feature cheap: the detail page,
/// reader, history, favourites and downloader all treat a collection like any
/// other network comic, so none of those paths need to know collections exist.
/// The work here is only translation — fan a detail load out to the members,
/// merge their chapter lists, and route a page load back to whichever member
/// owns that chapter (see [encodeCollectionChapterId]).
///
/// The collection is re-read from the store on every call rather than captured:
/// the user can rename it, reorder or drop members while the source stays
/// registered, and a captured copy would keep serving the old layout until the
/// next restart.
///
/// Ported from VeneraX `lib/foundation/comic_source/collection_source.dart`.
/// Unified alignments: the thumbnail config hook takes only an image key, and
/// [refreshCollectionSources] lives here (next to the store) instead of on the
/// source manager.
ComicSource buildComicCollectionSource(ComicCollection collection) {
  final sourceKey = collection.sourceKey;
  final id = collection.id;

  ComicCollection current() => ComicCollectionStore.find(id) ?? collection;

  return ComicSource(
    current().displayName,
    sourceKey,
    null, // account
    null, // categoryData
    null, // categoryComicsData
    null, // favoriteData
    const [], // explorePages
    null, // searchPageData
    null, // settings
    (_) => loadCollectionInfo(id),
    null, // loadComicThumbnail
    (_, ep) => loadCollectionPages(id, ep),
    // Images and covers belong to the members, so the auth/header config has to
    // come from the member's own source rather than from this one.
    (imageKey, comicId, epId) async =>
        collectionImageLoadingConfig(id, imageKey, epId),
    (imageKey) => collectionThumbnailLoadingConfig(id, imageKey),
    "", // filePath — built-in source, not a script on disk
    "", // url
    "1.0.0", // version
    null, // commentsLoader
    null, // sendCommentFunc
    null, // chapterCommentsLoader
    null, // sendChapterCommentFunc
    null, // likeOrUnlikeComic
    null, // voteCommentFunc
    null, // likeCommentFunc
    null, // idMatcher
    null, // translations
    null, // handleClickTagEvent
    null, // onTagSuggestionSelected
    null, // linkHandler
    false, // enableTagsSuggestions
    false, // enableTagsTranslate
    null, // starRatingFunc
    null, // archiveDownloader
  );
}

/// Re-registers the collection sources after the user created, edited or
/// deleted a collection.
///
/// Only these sources are rebuilt — a full reload would re-parse every script
/// and touch the JS engine, dropping source login state for an edit that has
/// nothing to do with scripts. A collection that was deleted loses its source,
/// which is intended: its comics are no longer reachable, and the
/// detail/reader pages already handle an unknown source key.
///
/// Must be called after any change to a collection's members or display mode:
/// the built source captures the configuration, so a stale one would keep
/// serving the previous chapter layout.
void refreshCollectionSources() {
  final manager = ComicSourceManager();
  for (final source in ComicSource.all().toList()) {
    if (ComicCollectionStore.isCollectionSourceKey(source.key)) {
      manager.remove(source.key);
    }
  }
  for (final collection in ComicCollectionStore.all()) {
    manager.add(buildComicCollectionSource(collection));
  }
}

/// What one member contributed to a collection's detail load.
class _MemberLoad {
  _MemberLoad(
    this.member, {
    this.chapters = const {},
    this.failed = false,
    this.updateTime,
    this.tags = const {},
    this.description = '',
    this.subtitle = '',
    this.title = '',
  });

  final CollectionMember member;

  /// The member's chapters, already keyed by collection chapter id.
  final Map<String, String> chapters;

  /// The member's tag map (author, artist, genre, ...). The collection borrows
  /// the first available member's, so its detail page and card carry the same
  /// author and tags as the story it groups.
  final Map<String, List<String>> tags;

  /// The member's own description, borrowed on the same terms as [tags].
  final String description;

  /// The member's author line. Carried through the load rather than read back
  /// off [member]: the member objects here predate this load's cache write, so
  /// theirs would still be empty the first time a collection opens.
  final String subtitle;

  /// The member's own title, carried for the same reason as [subtitle].
  final String title;

  /// The label to show for this member — a user-set display name wins, then the
  /// title this load just fetched, then whatever was cached, and only then the
  /// raw comic id. Without the freshly-fetched title, a collection opened for
  /// the first time labelled its tabs with comic ids.
  String get label {
    final own = member.displayName.trim();
    if (own.isNotEmpty) return own;
    if (title.trim().isNotEmpty) return title.trim();
    return member.label;
  }

  /// The member's own update time, when it reports one. The collection surfaces
  /// the latest across its members so follow-updates notices a new chapter in
  /// any of them.
  final String? updateTime;

  /// True when the member could not be read (source uninstalled, comic deleted,
  /// server unreachable). Its tab/entries stay listed but marked unavailable, so
  /// a temporary outage never silently shortens the collection.
  final bool failed;
}

/// Loads a member's chapter list, translated into collection chapter ids.
///
/// A member with no chapter list of its own contributes a single entry whose
/// member chapter id is empty — the sources expect a null chapter argument in
/// that case, which [CollectionChapterRef.memberChapterArg] encodes.
Future<_MemberLoad> _loadMember(String collectionId, CollectionMember m) async {
  String chapterId(String memberChapterId) => encodeCollectionChapterId(
    sourceKey: m.sourceKey,
    comicId: m.comicId,
    chapterId: memberChapterId,
  );

  try {
    final type = ComicType.fromKey(m.sourceKey);
    if (type == ComicType.local) {
      final local = LocalManager().find(m.comicId, ComicType.local);
      if (local == null) return _MemberLoad(m, failed: true);
      ComicCollectionStore.cacheMemberInfo(
        collectionId,
        m.sourceKey,
        m.comicId,
        title: local.title,
        subtitle: local.subtitle,
        // Stored with the scheme the image loaders recognise: a bare path would
        // be treated as a URL when the collection borrows this as its cover.
        cover: 'file://${local.coverFile.path}',
      );
      // A local comic keeps its tags as a plain list; the detail model wants a
      // namespaced map, and "tags" is the namespace the app already shows those
      // under elsewhere.
      final localTags = <String, List<String>>{
        if (local.subtitle.trim().isNotEmpty) 'author': [local.subtitle.trim()],
        if (local.tags.isNotEmpty) 'tags': List.of(local.tags),
      };
      final chapters = local.chapters;
      if (chapters == null) {
        return _MemberLoad(
          m,
          chapters: {chapterId(''): m.label},
          tags: localTags,
          description: local.description,
          subtitle: local.subtitle,
          title: local.title,
        );
      }
      return _MemberLoad(
        m,
        chapters: {
          for (final e in chapters.allChapters.entries)
            chapterId(e.key): e.value,
        },
        tags: localTags,
        description: local.description,
        subtitle: local.subtitle,
        title: local.title,
      );
    }

    final source = ComicSource.find(m.sourceKey);
    if (source?.loadComicInfo == null) return _MemberLoad(m, failed: true);
    final res = await source!.loadComicInfo!(m.comicId);
    if (res.error) return _MemberLoad(m, failed: true);
    final details = res.data;
    ComicCollectionStore.cacheMemberInfo(
      collectionId,
      m.sourceKey,
      m.comicId,
      title: details.title,
      subtitle: details.subTitle ?? '',
      cover: details.cover,
    );
    final updateTime = details.findUpdateTime();
    final tags = details.tags;
    final description = details.description ?? '';
    final chapters = details.chapters;
    if (chapters == null) {
      return _MemberLoad(
        m,
        chapters: {chapterId(''): m.label},
        updateTime: updateTime,
        tags: tags,
        description: description,
        subtitle: details.subTitle ?? '',
        title: details.title,
      );
    }
    return _MemberLoad(
      m,
      chapters: {
        for (final e in chapters.allChapters.entries) chapterId(e.key): e.value,
      },
      updateTime: updateTime,
      tags: tags,
      description: description,
      subtitle: details.subTitle ?? '',
      title: details.title,
    );
  } catch (e, s) {
    Log.error('ComicCollection', e, s);
    return _MemberLoad(m, failed: true);
  }
}

/// Builds the collection's detail: every member loaded in parallel, their
/// chapters merged per the collection's display mode.
///
/// A failed member does not fail the load. In `flat` mode its entry is listed
/// with an unavailable marker; in `tabs` mode its tab stays but holds a single
/// marker entry. Either way the chapter numbering the user already read against
/// keeps its shape instead of shifting under them.
Future<Res<ComicDetails>> loadCollectionInfo(String collectionId) async {
  final collection = ComicCollectionStore.find(collectionId);
  if (collection == null) {
    return Res.error('This collection no longer exists'.tl);
  }
  final members = collection.members;
  if (members.isEmpty) {
    return Res(
      ComicDetails.fromJson({
        'title': collection.displayName,
        'cover': collection.displayCover,
        'comicId': collectionId,
        'sourceKey': collection.sourceKey,
        'tags': <String, List<String>>{},
        'chapters': <String, String>{},
        'description': 'This collection is empty'.tl,
      }),
    );
  }

  // Members load in parallel: a collection of five network comics would
  // otherwise take five sequential round trips to open.
  final loads = await Future.wait(
    members.map((m) => _loadMember(collectionId, m)),
  );

  final unavailable = 'Unavailable'.tl;
  dynamic chapters;
  if (collection.displayMode == CollectionDisplayMode.tabs) {
    final grouped = <String, Map<String, String>>{};
    for (final load in loads) {
      var name = load.label;
      // Two members may share a title; group keys must stay distinct or one
      // tab would swallow the other's chapters.
      while (grouped.containsKey(name)) {
        name = '$name ';
      }
      grouped[name] = load.failed
          ? {
              encodeCollectionChapterId(
                sourceKey: load.member.sourceKey,
                comicId: load.member.comicId,
                chapterId: '',
              ): '[$unavailable] ${load.label}',
            }
          : load.chapters;
    }
    chapters = grouped;
  } else {
    final flat = <String, String>{};
    for (final load in loads) {
      if (load.failed) {
        flat[encodeCollectionChapterId(
              sourceKey: load.member.sourceKey,
              comicId: load.member.comicId,
              chapterId: '',
            )] =
            '[$unavailable] ${load.label}';
        continue;
      }
      flat.addAll(load.chapters);
    }
    chapters = flat;
  }

  // Re-read after the member caches were written so the name/cover fallbacks
  // reflect what just loaded rather than what was stored before.
  final fresh = ComicCollectionStore.find(collectionId) ?? collection;
  final failedCount = loads.where((e) => e.failed).length;

  // Author, tags and description are borrowed from the first member that loaded
  // — the collection is the same work, so repeating its metadata is what the
  // user expects on the card and the detail page. First available rather than
  // merged across members: merging would pile up near-duplicate tags and, for
  // author, could imply a co-authorship that doesn't exist.
  final infoSource = loads.firstWhereOrNull(
    (e) => !e.failed && (e.tags.isNotEmpty || e.description.isNotEmpty),
  );

  // The latest member update time becomes the collection's, so follow-updates
  // reacts to a new chapter in any member. Compared as strings: findUpdateTime
  // has already validated them into `YYYY-M-D`, and the padded form sorts
  // chronologically.
  String? latestUpdate;
  for (final load in loads) {
    final t = load.updateTime;
    if (t == null) continue;
    if (latestUpdate == null ||
        collectionUpdateSortKey(
              t,
            ).compareTo(collectionUpdateSortKey(latestUpdate)) >
            0) {
      latestUpdate = t;
    }
  }

  // A failure note has to be visible, so it goes above the borrowed
  // description rather than replacing it.
  final notice = failedCount == 0
      ? ''
      : '@n of the comics in this collection could not be loaded'.tlParams({
          'n': failedCount,
        });
  final borrowed = infoSource?.description ?? '';
  final description = notice.isEmpty
      ? borrowed
      : (borrowed.isEmpty ? notice : '$notice\n\n$borrowed');

  // The author line under the title, from the first member that reports one.
  final subtitle = loads
      .firstWhereOrNull((e) => !e.failed && e.subtitle.trim().isNotEmpty)
      ?.subtitle
      .trim();

  return Res(
    ComicDetails.fromJson({
      'title': fresh.displayName,
      'cover': fresh.displayCover,
      'comicId': collectionId,
      'sourceKey': fresh.sourceKey,
      'subtitle': subtitle,
      'tags': infoSource?.tags ?? <String, List<String>>{},
      'chapters': chapters,
      'updateTime': latestUpdate,
      'description': description,
    }),
  );
}

/// Routes a page load to the member that owns [ep].
///
/// Already-downloaded chapters are served from disk as `file://` paths, so a
/// comic downloaded before it joined a collection still reads offline and is not
/// pointlessly re-fetched. The reader understands those paths; the downloader
/// does not (it hands the key straight to the HTTP client), so [forDownload]
/// suppresses the local shortcut and always resolves the network pages.
///
/// A member that is local-only has no network side at all: it returns file paths
/// regardless, which is why downloading such a chapter is refused rather than
/// silently producing a broken chapter.
Future<Res<List<String>>> loadCollectionPages(
  String collectionId,
  String? ep, {
  bool forDownload = false,
}) async {
  final ref = decodeCollectionChapterId(ep);
  if (ref == null) {
    return Res.error('Unknown chapter'.tl);
  }
  final memberType = ComicType.fromKey(ref.sourceKey);

  // Local members have no network side at all.
  if (memberType == ComicType.local) {
    if (forDownload) {
      // The images are already on this device; copying them into a second
      // download would waste the space and is not what the user asked for.
      return Res.error('This comic is already stored on this device'.tl);
    }
    try {
      final images = await LocalManager().getImages(
        ref.comicId,
        ComicType.local,
        ref.chapterId.isEmpty ? 1 : ref.chapterId,
      );
      return Res(images);
    } catch (e, s) {
      Log.error('ComicCollection', e, s);
      return Res.error('This comic is no longer available'.tl);
    }
  }

  // A network member whose chapter is already downloaded reads from disk.
  if (!forDownload) {
    final local = LocalManager().find(ref.comicId, memberType);
    if (local != null &&
        (ref.chapterId.isEmpty ||
            local.downloadedChapters.contains(ref.chapterId))) {
      try {
        final images = await LocalManager().getImages(
          ref.comicId,
          memberType,
          ref.chapterId.isEmpty ? 1 : ref.chapterId,
        );
        if (images.isNotEmpty) return Res(images);
      } catch (e, s) {
        // Fall through to the network: a missing file is recoverable here.
        Log.error('ComicCollection', e, s);
      }
    }
  }

  final source = ComicSource.find(ref.sourceKey);
  if (source?.loadComicPages == null) {
    return Res.error('The source of this comic is not installed'.tl);
  }
  return source!.loadComicPages!(ref.comicId, ref.memberChapterArg);
}

/// Image loading config for a collection page, taken from the member source
/// that actually serves the image.
Future<Map<String, dynamic>> collectionImageLoadingConfig(
  String collectionId,
  String imageKey,
  String? epId,
) async {
  final ref = decodeCollectionChapterId(epId);
  if (ref == null) return {};
  final source = ComicSource.find(ref.sourceKey);
  final config = await source?.getImageLoadingConfig?.call(
    imageKey,
    ref.comicId,
    ref.memberChapterArg ?? '',
  );
  return config ?? {};
}

/// Thumbnail/cover loading config for a collection.
///
/// A collection's cover is usually borrowed from a member, and fetching it may
/// need that member's headers (a WebDAV library cover needs Basic auth). Only
/// the borrowed case forwards: a cover the user picked is loaded plainly.
Future<Map<String, dynamic>> collectionThumbnailLoadingConfig(
  String collectionId,
  String imageKey,
) async {
  final collection = ComicCollectionStore.find(collectionId);
  final owner = collection?.coverOwner;
  if (owner == null) return {};
  final source = ComicSource.find(owner.sourceKey);
  // Unified thumbnail hooks take only the image key; the member source
  // resolves whatever context it needs on its own side.
  return await source?.getThumbnailLoadingConfig?.call(imageKey) ?? {};
}

/// Expands collection placeholder chapters into their members' real chapters.
///
/// A failed member and a single-chapter member both surface as one entry with
/// an empty member chapter id. Re-resolve the member details here so the
/// download fetch sends real chapter arguments instead of null, and expand the
/// chapter filter to match so the new keys are not filtered out.
///
/// Pure in/out: returns the inputs unchanged when there is nothing to expand,
/// and discards partial work when [isCancelled] fires.
Future<CollectionChapterExpansion> resolveCollectionDownloadChapters({
  required ComicDetails comic,
  required List<String>? chapters,
  required bool Function() isCancelled,
}) async {
  CollectionChapterExpansion unchanged() => (comic: comic, chapters: chapters);
  final current = comic.chapters;
  if (current == null) return unchanged();
  final pending = current.allChapters.keys.where(
    (key) => chapters == null || chapters.contains(key),
  );
  final replacements = <String, Map<String, String>>{};
  for (final key in pending) {
    if (isCancelled()) return unchanged();
    final ref = decodeCollectionChapterId(key);
    if (ref == null ||
        ref.chapterId.isNotEmpty ||
        ComicType.fromKey(ref.sourceKey) == ComicType.local) {
      continue;
    }
    // Failed member details use the same empty id as single-chapter comics.
    // Resolve it before sending a null chapter argument to the member source.
    final memberSource = ComicSource.find(ref.sourceKey);
    if (memberSource?.loadComicInfo == null) {
      throw 'The source of this comic is not installed'.tl;
    }
    final result = await memberSource!.loadComicInfo!(ref.comicId);
    if (isCancelled()) return unchanged();
    if (result.error) throw result.errorMessage!;
    final memberChapters = result.data.chapters?.allChapters;
    if (memberChapters == null) continue;
    if (memberChapters.isEmpty) throw 'Unknown chapter'.tl;
    replacements[key] = {
      for (final entry in memberChapters.entries)
        encodeCollectionChapterId(
          sourceKey: ref.sourceKey,
          comicId: ref.comicId,
          chapterId: entry.key,
        ): entry.value,
    };
  }
  if (replacements.isEmpty) return unchanged();

  Map<String, String> expand(Map<String, String> entries) => {
    for (final entry in entries.entries)
      ...replacements[entry.key] ?? {entry.key: entry.value},
  };
  final expanded = ComicDetails.fromJson({
    ...comic.toJson(),
    'subtitle': comic.subTitle,
    'chapters': current.isGrouped
        ? {
            for (final group in current.groups)
              group: expand(current.getGroup(group)),
          }
        : expand(current.allChapters),
  });
  // Only pending entries expand, so completed chapters keep their positions.
  return (
    comic: expanded,
    chapters: chapters
        ?.expand((key) => replacements[key]?.keys ?? [key])
        .toList(),
  );
}

class _CollectionDownloadHooksImpl implements CollectionDownloadHooks {
  const _CollectionDownloadHooksImpl();

  @override
  bool isCollectionSource(String sourceKey) =>
      ComicCollectionStore.isCollectionSourceKey(sourceKey);

  @override
  Future<Res<List<String>>> loadPagesForDownload(String comicId, String? ep) =>
      loadCollectionPages(comicId, ep, forDownload: true);

  @override
  Future<CollectionChapterExpansion> resolveChapters({
    required ComicDetails comic,
    required List<String>? chapters,
    required bool Function() isCancelled,
  }) => resolveCollectionDownloadChapters(
    comic: comic,
    chapters: chapters,
    isCancelled: isCancelled,
  );
}

/// Registers the collection download hooks so the downloader routes collection
/// chapters through the forDownload page variant and expands placeholder
/// chapters. Called once from app bootstrap; pass null via
/// [configureCollectionDownloadHooks] to restore direct-source behavior.
void registerCollectionDownloadHooks() {
  configureCollectionDownloadHooks(const _CollectionDownloadHooksImpl());
}
