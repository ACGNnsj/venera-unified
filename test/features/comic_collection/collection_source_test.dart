import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_collection/collection_source.dart';
import 'package:venera_unified/features/comic_collection/comic_collection_store.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDir;
  late dynamic originalCollections;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('venera-collection-src-');
    App.dataPath = dataDir.path;
    originalCollections = appdata.settings[ComicCollectionStore.settingsKey];
    appdata.settings[ComicCollectionStore.settingsKey] = [];
    await appdata.init();
  });

  tearDown(() async {
    appdata.settings[ComicCollectionStore.settingsKey] = originalCollections;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (dataDir.existsSync()) {
      dataDir.deleteSync(recursive: true);
    }
  });

  test('buildComicCollectionSource wires a real source', () {
    final collection = ComicCollection(
      id: 'c1',
      sourceKey: 'comic_collection_c1',
      name: 'My Mix',
      members: [CollectionMember(sourceKey: 'jm', comicId: '1')],
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final source = buildComicCollectionSource(collection);

    expect(source.key, 'comic_collection_c1');
    expect(source.name, 'My Mix');
    expect(source.loadComicInfo, isNotNull);
    expect(source.loadComicPages, isNotNull);
    expect(source.getImageLoadingConfig, isNotNull);
    expect(source.getThumbnailLoadingConfig, isNotNull);
    expect(source.filePath, '');
    expect(source.url, '');
    expect(source.version, '1.0.0');
    expect(source.searchPageData, isNull);
    expect(source.explorePages, isEmpty);
    expect(source.account, isNull);
    expect(source.linkHandler, isNull);
  });

  test('built source falls back to the member title for its name', () {
    final collection = ComicCollection(
      id: 'c2',
      sourceKey: 'comic_collection_c2',
      name: '  ',
      members: [
        CollectionMember(
          sourceKey: 'jm',
          comicId: '1',
          cachedTitle: 'Borrowed Title',
        ),
      ],
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect(buildComicCollectionSource(collection).name, 'Borrowed Title');
  });

  test('empty collection detail short-circuits without members', () async {
    final collection = ComicCollectionStore.create(name: 'Empty');
    final source = buildComicCollectionSource(collection);
    final res = await source.loadComicInfo!(collection.id);
    expect(res.error, isFalse);
    expect(res.data.title, 'Empty');
    expect(res.data.comicId, collection.id);
    expect(res.data.sourceKey, collection.sourceKey);
    expect(res.data.chapters!.allChapters, isEmpty);
  });

  test('missing collection detail errors instead of throwing', () async {
    final res = await loadCollectionInfo('does-not-exist');
    expect(res.error, isTrue);
  });

  test('foreign chapter id errors instead of throwing', () async {
    final res = await loadCollectionPages('whatever', 'not-a-collection-id');
    expect(res.error, isTrue);
  });
}
