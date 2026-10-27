import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_collection/collection_source.dart';
import 'package:venera_unified/features/comic_collection/comic_collection_chapter_id.dart';
import 'package:venera_unified/features/comic_collection/comic_collection_store.dart';
import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/features/local_comics/collection_download_hooks.dart';
import 'package:venera_unified/features/local_comics/download_directory_allocator.dart';
import 'package:venera_unified/features/local_comics/download_task_storage.dart';
import 'package:venera_unified/features/local_comics/local_comics.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/comic_type.dart';
import 'package:venera_unified/foundation/res.dart';
import 'package:venera_unified/network/images.dart';

void main() {
  const memberKey = 'hook_test_member';
  const plainKey = 'hook_test_plain';

  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6uwAAAABJRU5ErkJggg==',
  );

  late Directory dataDir;
  late dynamic originalCollections;
  late dynamic originalThreads;
  late CollectionDownloadHooks? originalHooks;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('venera-hook-parity-');
    App.dataPath = dataDir.path;
    originalCollections = appdata.settings[ComicCollectionStore.settingsKey];
    originalThreads = appdata.settings['downloadThreads'];
    originalHooks = collectionDownloadHooks;
    appdata.settings[ComicCollectionStore.settingsKey] = [];
    appdata.settings['downloadThreads'] = 1;
    configureCollectionDownloadHooks(null);
    await appdata.init();
  });

  tearDown(() async {
    configureCollectionDownloadHooks(originalHooks);
    ComicSourceManager().remove(memberKey);
    ComicSourceManager().remove(plainKey);
    appdata.settings[ComicCollectionStore.settingsKey] = originalCollections;
    appdata.settings['downloadThreads'] = originalThreads;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (dataDir.existsSync()) {
      dataDir.deleteSync(recursive: true);
    }
  });

  ComicSource testSource(
    String key, {
    LoadComicFunc? loadComicInfo,
    LoadComicPagesFunc? loadComicPages,
  }) {
    return ComicSource(
      'Test Source',
      key,
      null,
      null,
      null,
      null,
      const [],
      null,
      null,
      loadComicInfo,
      null,
      loadComicPages,
      null,
      null,
      '',
      '',
      '1.0.0',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      false,
      false,
      null,
      null,
    );
  }

  ComicDetails detailsWithChapters(
    String sourceKey,
    String comicId,
    Map<String, String> chapters,
  ) => ComicDetails.fromJson({
    'title': 'T',
    'subtitle': '',
    'cover': 'cover.jpg',
    'description': '',
    'tags': <String, List<String>>{},
    'chapters': chapters,
    'sourceKey': sourceKey,
    'comicId': comicId,
  });

  Stream<ImageDownloadProgress> imageLoader(
    String key,
    String? _,
    String _,
    String _,
  ) async* {
    yield ImageDownloadProgress(
      currentBytes: png.length,
      totalBytes: png.length,
      imageBytes: png,
    );
  }

  Stream<ImageDownloadProgress> thumbLoader(String _, String _) => Stream.value(
    ImageDownloadProgress(
      currentBytes: png.length,
      totalBytes: png.length,
      imageBytes: png,
    ),
  );

  group('hooks registry', () {
    test('unregistered by default, register/unregister round-trips', () {
      expect(collectionDownloadHooks, isNull);
      registerCollectionDownloadHooks();
      final hooks = collectionDownloadHooks!;
      expect(hooks.isCollectionSource('comic_collection_x'), isTrue);
      expect(hooks.isCollectionSource('jm'), isFalse);
      configureCollectionDownloadHooks(null);
      expect(collectionDownloadHooks, isNull);
    });
  });

  group('unregistered parity', () {
    test('pages resolve via the source directly, filter untouched', () async {
      final root = Directory.systemTemp.createTempSync('venera-hook-plain-');
      try {
        final storage = _TaskStorage(root.path);
        final pageCalls = <String?>[];
        final source = testSource(
          plainKey,
          loadComicPages: (_, ep) async {
            pageCalls.add(ep);
            return const Res(['p1.png']);
          },
        );
        final task = ImagesDownloadTask(
          storage: storage,
          source: source,
          comicId: 'plain-comic',
          comic: detailsWithChapters(plainKey, 'plain-comic', {
            'ch1': 'Chapter 1',
          }),
          chapters: const ['ch1'],
          loadThumbnail: thumbLoader,
          loadImage: imageLoader,
        );
        try {
          task.resume();
          await task.debugResumeFuture;
          expect(task.isError, isFalse);
          expect(pageCalls, ['ch1']);
          // No expansion ran: the persisted filter is the original selection.
          expect(task.toJson()['chapters'], ['ch1']);
          expect(storage.completed, [same(task)]);
          expect(File('${task.path}/ch1/0.png').existsSync(), isTrue);
        } finally {
          task.pause();
          await task.pendingCleanup;
          task.dispose();
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    });
  });

  group('resolveCollectionDownloadChapters', () {
    test('expands placeholders into member chapters', () async {
      ComicSourceManager().add(
        testSource(
          memberKey,
          loadComicInfo: (_) async =>
              Res(detailsWithChapters(memberKey, 'comicA', {'m1': 'M1'})),
        ),
      );
      final placeholder = encodeCollectionChapterId(
        sourceKey: memberKey,
        comicId: 'comicA',
        chapterId: '',
      );
      final expansion = await resolveCollectionDownloadChapters(
        comic: detailsWithChapters('comic_collection_c', 'c', {
          placeholder: '[x] member',
        }),
        chapters: [placeholder],
        isCancelled: () => false,
      );
      final expanded = encodeCollectionChapterId(
        sourceKey: memberKey,
        comicId: 'comicA',
        chapterId: 'm1',
      );
      expect(expansion.comic.chapters!.allChapters.keys, [expanded]);
      expect(expansion.chapters, [expanded]);
    });

    test('leaves real chapter keys and null chapters alone', () async {
      final real = encodeCollectionChapterId(
        sourceKey: memberKey,
        comicId: 'comicA',
        chapterId: 'm1',
      );
      final comic = detailsWithChapters('comic_collection_c', 'c', {
        real: 'M1',
      });
      final expansion = await resolveCollectionDownloadChapters(
        comic: comic,
        chapters: [real],
        isCancelled: () => false,
      );
      expect(identical(expansion.comic, comic), isTrue);
      expect(expansion.chapters, [real]);

      final single = ComicDetails.fromJson({
        'title': 'T',
        'subtitle': '',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'chapters': null,
        'sourceKey': 'comic_collection_c',
        'comicId': 'c',
      });
      final untouched = await resolveCollectionDownloadChapters(
        comic: single,
        chapters: null,
        isCancelled: () => false,
      );
      expect(identical(untouched.comic, single), isTrue);
      expect(untouched.chapters, isNull);
    });

    test('cancellation discards partial work', () async {
      final placeholder = encodeCollectionChapterId(
        sourceKey: memberKey,
        comicId: 'comicA',
        chapterId: '',
      );
      final comic = detailsWithChapters('comic_collection_c', 'c', {
        placeholder: '[x] member',
      });
      final expansion = await resolveCollectionDownloadChapters(
        comic: comic,
        chapters: [placeholder],
        isCancelled: () => true,
      );
      expect(identical(expansion.comic, comic), isTrue);
      expect(expansion.chapters, [placeholder]);
    });

    test('uninstalled member source throws instead of expanding', () async {
      final placeholder = encodeCollectionChapterId(
        sourceKey: 'hook_test_gone',
        comicId: 'comicA',
        chapterId: '',
      );
      await expectLater(
        resolveCollectionDownloadChapters(
          comic: detailsWithChapters('comic_collection_c', 'c', {
            placeholder: '[x] member',
          }),
          chapters: [placeholder],
          isCancelled: () => false,
        ),
        throwsA('The source of this comic is not installed'),
      );
    });
  });

  group('registered routing', () {
    test('collection task downloads via member sources', () async {
      registerCollectionDownloadHooks();
      final root = Directory.systemTemp.createTempSync('venera-hook-reg-');
      try {
        final storage = _TaskStorage(root.path);
        final pageCalls = <(String, String?)>[];
        ComicSourceManager().add(
          testSource(
            memberKey,
            loadComicInfo: (_) async =>
                Res(detailsWithChapters(memberKey, 'comicA', {'m1': 'M1'})),
            loadComicPages: (id, ep) async {
              pageCalls.add((id, ep));
              return const Res(['mp.png']);
            },
          ),
        );
        final collection = ComicCollectionStore.create(
          name: 'Hooked',
          members: [CollectionMember(sourceKey: memberKey, comicId: 'comicA')],
        );
        final placeholder = encodeCollectionChapterId(
          sourceKey: memberKey,
          comicId: 'comicA',
          chapterId: '',
        );
        final task = ImagesDownloadTask(
          storage: storage,
          source: buildComicCollectionSource(collection),
          comicId: collection.id,
          comic: detailsWithChapters(collection.sourceKey, collection.id, {
            placeholder: '[x] member',
          }),
          chapters: [placeholder],
          loadThumbnail: thumbLoader,
          loadImage: imageLoader,
        );
        try {
          task.resume();
          await task.debugResumeFuture;
          expect(task.isError, isFalse);
          // forDownload routing: real chapter argument reaches the member.
          expect(pageCalls, [('comicA', 'm1')]);
          final expanded = encodeCollectionChapterId(
            sourceKey: memberKey,
            comicId: 'comicA',
            chapterId: 'm1',
          );
          expect(task.toJson()['chapters'], [expanded]);
          expect(storage.completed, [same(task)]);
        } finally {
          task.pause();
          await task.pendingCleanup;
          task.dispose();
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    });
  });
}

class _TaskStorage implements DownloadTaskStorage {
  _TaskStorage(this.path);
  @override
  final String path;
  final completed = <DownloadTask>[];

  @override
  Future<DownloadDirectoryAllocation> allocateDownloadDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    final directory = Directory('$path/output')..createSync();
    return DownloadDirectoryAllocation(directory, isNew: true);
  }

  @override
  LocalComic? find(String id, ComicType type) => null;

  @override
  Future<void> saveCurrentDownloadingTasks() async {}

  @override
  void completeTask(DownloadTask task) {
    completed.add(task);
  }

  @override
  void removeTask(DownloadTask task) {}
}
