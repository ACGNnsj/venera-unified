import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_collection/comic_collection_store.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/file_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDir;
  late dynamic originalCollections;
  late dynamic originalDetailMode;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('venera-collections-');
    App.dataPath = dataDir.path;
    originalCollections = appdata.settings[ComicCollectionStore.settingsKey];
    originalDetailMode =
        appdata.settings[ComicCollectionStore.detailDisplayModeSettingsKey];
    appdata.settings[ComicCollectionStore.settingsKey] = [];
    appdata.settings[ComicCollectionStore.detailDisplayModeSettingsKey] = null;
    await appdata.init();
  });

  tearDown(() async {
    appdata.settings[ComicCollectionStore.settingsKey] = originalCollections;
    appdata.settings[ComicCollectionStore.detailDisplayModeSettingsKey] =
        originalDetailMode;
    // Store writes are fire-and-forget; let them land before removing the dir.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (dataDir.existsSync()) {
      dataDir.deleteSync(recursive: true);
    }
  });

  CollectionMember member(String sourceKey, String comicId) =>
      CollectionMember(sourceKey: sourceKey, comicId: comicId);

  group('create', () {
    test('assigns an id and a persisted source key', () {
      final c = ComicCollectionStore.create(name: ' Mix ');
      expect(c.id, isNotEmpty);
      expect(c.sourceKey, 'comic_collection_${c.id}');
      expect(c.name, 'Mix');
      expect(c.displayMode, CollectionDisplayMode.flat);
      expect(ComicCollectionStore.all().map((e) => e.id), [c.id]);
      expect(ComicCollectionStore.hasAny, isTrue);
    });

    test('two creations never share an id', () {
      final a = ComicCollectionStore.create();
      final b = ComicCollectionStore.create();
      expect(a.id == b.id, isFalse);
      expect(ComicCollectionStore.all(), hasLength(2));
    });

    test('drops blanks, nested collections and duplicates', () {
      final c = ComicCollectionStore.create(
        members: [
          member('jm', '1'),
          member('jm', '1'),
          member('', 'x'),
          member('y', ''),
          member('comic_collection_other', 'z'),
        ],
      );
      expect(c.members.map((m) => m.refKey), ['jm/1']);
    });
  });

  group('update', () {
    test('edits fields and trims text', () {
      final c = ComicCollectionStore.create(name: 'old');
      final updated = ComicCollectionStore.update(
        c.id,
        name: '  new  ',
        customCover: '  cover.png  ',
        displayMode: CollectionDisplayMode.tabs,
        members: [member('jm', '1')],
      )!;
      expect(updated.name, 'new');
      expect(updated.customCover, 'cover.png');
      expect(updated.displayMode, CollectionDisplayMode.tabs);
      expect(updated.members.map((m) => m.refKey), ['jm/1']);
    });

    test('unknown id returns null and writes nothing', () {
      final before = appdata.settings[ComicCollectionStore.settingsKey];
      expect(ComicCollectionStore.update('nope', name: 'x'), isNull);
      expect(
        identical(appdata.settings[ComicCollectionStore.settingsKey], before),
        isTrue,
      );
    });
  });

  group('addMembers/removeMember/reorderMember', () {
    test('appends new members and reports the count', () {
      final c = ComicCollectionStore.create(members: [member('jm', '1')]);
      final added = ComicCollectionStore.addMembers(c.id, [
        member('jm', '1'),
        member('jm', '2'),
        member('comic_collection_x', 'y'),
      ]);
      expect(added, 1);
      expect(ComicCollectionStore.find(c.id)!.members.map((m) => m.refKey), [
        'jm/1',
        'jm/2',
      ]);
    });

    test('unknown collection adds nothing', () {
      expect(ComicCollectionStore.addMembers('nope', [member('jm', '1')]), 0);
    });

    test('removeMember drops the pair only', () {
      final c = ComicCollectionStore.create(
        members: [member('jm', '1'), member('jm', '2')],
      );
      ComicCollectionStore.removeMember(c.id, 'jm', '1');
      expect(ComicCollectionStore.find(c.id)!.members.map((m) => m.refKey), [
        'jm/2',
      ]);
      // Unknown targets are silent no-ops.
      ComicCollectionStore.removeMember(c.id, 'jm', 'zzz');
      ComicCollectionStore.removeMember('nope', 'jm', '2');
    });

    test('reorderMember moves and clamps, bad indexes are no-ops', () {
      final c = ComicCollectionStore.create(
        members: [member('jm', '1'), member('jm', '2'), member('jm', '3')],
      );
      ComicCollectionStore.reorderMember(c.id, 0, 2);
      expect(ComicCollectionStore.find(c.id)!.members.map((m) => m.comicId), [
        '2',
        '3',
        '1',
      ]);
      ComicCollectionStore.reorderMember(c.id, 0, 99);
      expect(ComicCollectionStore.find(c.id)!.members.map((m) => m.comicId), [
        '3',
        '1',
        '2',
      ]);
      ComicCollectionStore.reorderMember(c.id, 9, 0);
      ComicCollectionStore.reorderMember('nope', 0, 0);
      expect(ComicCollectionStore.find(c.id)!.members.map((m) => m.comicId), [
        '3',
        '1',
        '2',
      ]);
    });
  });

  group('remove/reorder collections', () {
    test('remove drops one collection', () {
      final a = ComicCollectionStore.create(name: 'a');
      final b = ComicCollectionStore.create(name: 'b');
      ComicCollectionStore.remove(a.id);
      expect(ComicCollectionStore.all().map((e) => e.id), [b.id]);
      ComicCollectionStore.remove('nope');
      expect(ComicCollectionStore.all(), hasLength(1));
    });

    test('reorder moves and ignores bad indexes', () {
      final a = ComicCollectionStore.create(name: 'a');
      final b = ComicCollectionStore.create(name: 'b');
      ComicCollectionStore.reorder(0, 1);
      expect(ComicCollectionStore.all().map((e) => e.id), [b.id, a.id]);
      ComicCollectionStore.reorder(7, 0);
      expect(ComicCollectionStore.all().map((e) => e.id), [b.id, a.id]);
    });
  });

  group('cacheMemberInfo', () {
    test('writes back display fields on change only', () {
      final c = ComicCollectionStore.create(members: [member('jm', '1')]);
      ComicCollectionStore.cacheMemberInfo(
        c.id,
        'jm',
        '1',
        title: 'Title',
        subtitle: 'Author',
        cover: 'https://x/cover.jpg',
      );
      final m = ComicCollectionStore.find(c.id)!.members.single;
      expect(m.cachedTitle, 'Title');
      expect(m.cachedSubtitle, 'Author');
      expect(m.cachedCover, 'https://x/cover.jpg');

      // Same values: no rewrite, the stored list keeps its identity.
      final before = appdata.settings[ComicCollectionStore.settingsKey];
      ComicCollectionStore.cacheMemberInfo(
        c.id,
        'jm',
        '1',
        title: 'Title',
        subtitle: 'Author',
        cover: 'https://x/cover.jpg',
      );
      expect(
        identical(appdata.settings[ComicCollectionStore.settingsKey], before),
        isTrue,
      );
    });

    test('empty titles never overwrite, missing targets are silent', () {
      final c = ComicCollectionStore.create(members: [member('jm', '1')]);
      ComicCollectionStore.cacheMemberInfo(c.id, 'jm', '1', title: 'Kept');
      ComicCollectionStore.cacheMemberInfo(c.id, 'jm', '1', title: '');
      expect(
        ComicCollectionStore.find(c.id)!.members.single.cachedTitle,
        'Kept',
      );
      ComicCollectionStore.cacheMemberInfo('nope', 'jm', '1', title: 'x');
      ComicCollectionStore.cacheMemberInfo(c.id, 'jm', 'zzz', title: 'x');
    });
  });

  group('queries', () {
    test('find, findBySourceKey, containing, isMember', () {
      final c = ComicCollectionStore.create(members: [member('jm', '1')]);
      expect(ComicCollectionStore.find(c.id)!.sourceKey, c.sourceKey);
      expect(ComicCollectionStore.find('nope'), isNull);
      expect(ComicCollectionStore.findBySourceKey(c.sourceKey)!.id, c.id);
      expect(ComicCollectionStore.findBySourceKey(null), isNull);
      expect(ComicCollectionStore.findBySourceKey('nope'), isNull);
      expect(ComicCollectionStore.containing('jm', '1').map((e) => e.id), [
        c.id,
      ]);
      expect(ComicCollectionStore.containing('jm', 'zzz'), isEmpty);
      expect(ComicCollectionStore.isMember('jm', '1'), isTrue);
      expect(ComicCollectionStore.isMember('jm', 'zzz'), isFalse);
    });

    test('isCollectionSourceKey matches the prefix only', () {
      expect(
        ComicCollectionStore.isCollectionSourceKey('comic_collection_x'),
        isTrue,
      );
      expect(ComicCollectionStore.isCollectionSourceKey('jm'), isFalse);
      expect(ComicCollectionStore.isCollectionSourceKey(null), isFalse);
      expect(ComicCollectionStore.isCollectionSourceKey(''), isFalse);
    });
  });

  group('all() hardening', () {
    test('skips garbage, blanks and duplicate ids/keys', () {
      appdata.settings[ComicCollectionStore.settingsKey] = [
        'not a map',
        42,
        {'id': '', 'sourceKey': 'comic_collection_e', 'members': []},
        {
          'id': 'a',
          'sourceKey': 'comic_collection_a',
          'members': [],
          'createdAt': 0,
        },
        {
          'id': 'a',
          'sourceKey': 'comic_collection_dup_id',
          'members': [],
          'createdAt': 0,
        },
        {
          'id': 'b',
          'sourceKey': 'comic_collection_a',
          'members': [],
          'createdAt': 0,
        },
      ];
      final all = ComicCollectionStore.all();
      expect(all.map((e) => e.id), ['a']);
    });

    test('non-list storage reads as empty', () {
      appdata.settings[ComicCollectionStore.settingsKey] = 'nope';
      expect(ComicCollectionStore.all(), isEmpty);
      expect(ComicCollectionStore.hasAny, isFalse);
      appdata.settings[ComicCollectionStore.settingsKey] = null;
      expect(ComicCollectionStore.all(), isEmpty);
    });
  });

  group('ComicCollection.fromJson hardening', () {
    test('member list filters blanks, nests and dupes', () {
      final c = ComicCollection.fromJson({
        'id': 'c',
        'sourceKey': 'comic_collection_c',
        'members': [
          'junk',
          {'sourceKey': '', 'comicId': 'x'},
          {'sourceKey': 'comic_collection_o', 'comicId': 'y'},
          {'sourceKey': 'jm', 'comicId': '1'},
          {'sourceKey': 'jm', 'comicId': '1'},
        ],
      });
      expect(c.members.map((m) => m.refKey), ['jm/1']);
    });

    test('missing sourceKey is backfilled, bad scalars fall back', () {
      final c = ComicCollection.fromJson({'id': 'c'});
      expect(c.sourceKey, 'comic_collection_c');
      expect(c.name, '');
      expect(c.displayMode, CollectionDisplayMode.flat);
      expect(c.createdAt.millisecondsSinceEpoch, 0);
      final badMode = ComicCollection.fromJson({
        'id': 'd',
        'displayMode': 'sideways',
        'createdAt': 'not-an-int',
      });
      expect(badMode.displayMode, CollectionDisplayMode.flat);
      expect(badMode.createdAt.millisecondsSinceEpoch, 0);
      final tabs = ComicCollection.fromJson({'id': 't', 'displayMode': 'tabs'});
      expect(tabs.displayMode, CollectionDisplayMode.tabs);
    });

    test('toJson round-trips through the store', () {
      final c = ComicCollectionStore.create(
        name: 'Round',
        members: [
          CollectionMember(
            sourceKey: 'jm',
            comicId: '1',
            displayName: 'Vol 1',
            cachedTitle: 'T',
            cachedSubtitle: 'S',
            cachedCover: 'C',
          ),
        ],
        displayMode: CollectionDisplayMode.tabs,
      );
      final back = ComicCollection.fromJson(
        ComicCollectionStore.find(c.id)!.toJson(),
      );
      expect(back.id, c.id);
      expect(back.sourceKey, c.sourceKey);
      expect(back.name, 'Round');
      expect(back.displayMode, CollectionDisplayMode.tabs);
      expect(back.members.single.displayName, 'Vol 1');
      expect(back.members.single.cachedCover, 'C');
    });
  });

  group('display fallbacks', () {
    test('displayName prefers name, then member title, then id', () {
      final named = ComicCollection(
        id: 'n',
        sourceKey: 'comic_collection_n',
        name: 'Named',
        members: [],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(named.displayName, 'Named');
      final borrowed = ComicCollection(
        id: 'b',
        sourceKey: 'comic_collection_b',
        name: '  ',
        members: [
          CollectionMember(sourceKey: 'jm', comicId: '1', cachedTitle: 'M1'),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(borrowed.displayName, 'M1');
      final bare = ComicCollection(
        id: 'x',
        sourceKey: 'comic_collection_x',
        name: '',
        members: [member('jm', '1')],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(bare.displayName, 'x');
    });

    test('displayCover and coverOwner follow the same chain', () {
      final custom = ComicCollection(
        id: 'c',
        sourceKey: 'comic_collection_c',
        name: '',
        members: [
          CollectionMember(
            sourceKey: 'jm',
            comicId: '1',
            cachedCover: 'https://m/1.jpg',
          ),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        customCover: 'collection://mine.png',
      );
      expect(
        custom.displayCover,
        'file://${FilePath.join(dataDir.path, 'collection_covers', 'mine.png')}',
      );
      expect(custom.coverOwner, isNull);
      final borrowed = ComicCollection(
        id: 'b',
        sourceKey: 'comic_collection_b',
        name: '',
        members: [
          CollectionMember(sourceKey: 'jm', comicId: '1'),
          CollectionMember(
            sourceKey: 'jm',
            comicId: '2',
            cachedCover: 'https://m/2.jpg',
          ),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(borrowed.displayCover, 'https://m/2.jpg');
      expect(borrowed.coverOwner!.comicId, '2');
      final empty = ComicCollection(
        id: 'e',
        sourceKey: 'comic_collection_e',
        name: '',
        members: [],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(empty.displayCover, '');
      expect(empty.coverOwner, isNull);
    });

    test('member label never empty', () {
      expect(member('jm', '9').label, '9');
      expect(
        CollectionMember(
          sourceKey: 'jm',
          comicId: '9',
          cachedTitle: 'Cached',
        ).label,
        'Cached',
      );
      expect(
        CollectionMember(
          sourceKey: 'jm',
          comicId: '9',
          displayName: ' Own ',
          cachedTitle: 'Cached',
        ).label,
        'Own',
      );
    });
  });

  group('detail display mode preference', () {
    test('defaults to chapters, round-trips covers', () {
      expect(
        ComicCollectionStore.detailDisplayMode,
        CollectionDetailDisplayMode.chapters,
      );
      ComicCollectionStore.setDetailDisplayMode(
        CollectionDetailDisplayMode.covers,
      );
      expect(
        ComicCollectionStore.detailDisplayMode,
        CollectionDetailDisplayMode.covers,
      );
      expect(
        appdata.settings[ComicCollectionStore.detailDisplayModeSettingsKey],
        'covers',
      );
      ComicCollectionStore.setDetailDisplayMode(
        CollectionDetailDisplayMode.chapters,
      );
      expect(
        ComicCollectionStore.detailDisplayMode,
        CollectionDetailDisplayMode.chapters,
      );
    });

    test('unknown stored value falls back to chapters', () {
      appdata.settings[ComicCollectionStore.detailDisplayModeSettingsKey] =
          'sideways';
      expect(
        ComicCollectionStore.detailDisplayMode,
        CollectionDetailDisplayMode.chapters,
      );
      expect(
        CollectionDetailDisplayMode.fromName(null),
        CollectionDetailDisplayMode.chapters,
      );
    });
  });

  group('cover refs', () {
    test('localCoverRef and resolveCover', () {
      expect(ComicCollectionStore.localCoverRef('a.png'), 'collection://a.png');
      expect(
        ComicCollectionStore.resolveCover('collection://a.png'),
        'file://${FilePath.join(dataDir.path, 'collection_covers', 'a.png')}',
      );
      expect(ComicCollectionStore.resolveCover('collection://'), '');
      expect(
        ComicCollectionStore.resolveCover('https://x/y.jpg'),
        'https://x/y.jpg',
      );
      expect(ComicCollectionStore.resolveCover(''), '');
    });
  });
}
