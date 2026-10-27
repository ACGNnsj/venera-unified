import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_collection/comic_collection_chapter_id.dart';

void main() {
  group('encode/decode round-trip', () {
    test('basic address survives the round-trip', () {
      const ref = CollectionChapterRef(
        sourceKey: 'jm',
        comicId: '123456',
        chapterId: '7',
      );
      final id = encodeCollectionChapterId(
        sourceKey: ref.sourceKey,
        comicId: ref.comicId,
        chapterId: ref.chapterId,
      );
      expect(id.startsWith('cx1:'), isTrue);
      expect(decodeCollectionChapterId(id), ref);
      expect(isCollectionChapterId(id), isTrue);
    });

    test('empty chapter id means a null member chapter argument', () {
      final id = encodeCollectionChapterId(
        sourceKey: 'copy_manga',
        comicId: 'abc',
        chapterId: '',
      );
      final ref = decodeCollectionChapterId(id)!;
      expect(ref.chapterId, '');
      expect(ref.memberChapterArg, isNull);
    });

    test('non-empty chapter id passes through as the member argument', () {
      final id = encodeCollectionChapterId(
        sourceKey: 's',
        comicId: 'c',
        chapterId: 'ep12',
      );
      expect(decodeCollectionChapterId(id)!.memberChapterArg, 'ep12');
    });

    test('opaque member ids with separators survive', () {
      // WebDAV chapter ids are paths; script sources hand out colons/slashes.
      const cases = [
        ('webdav_library', 'my/dir/comic', 'vol 1/ch:2'),
        ('jm', 'id:with:colons', 'a/b/c'),
        ('s', 'c', '  spaces  '),
        ('s', 'c', '中文标题 第01话'),
      ];
      final longId = 'x' * 500;
      for (final (sourceKey, comicId, chapterId) in [
        ...cases,
        ('s', 'c', longId),
      ]) {
        final id = encodeCollectionChapterId(
          sourceKey: sourceKey,
          comicId: comicId,
          chapterId: chapterId,
        );
        // The id itself must stay splittable: exactly 4 colon segments.
        expect(id.split(':').length, 4);
        expect(
          decodeCollectionChapterId(id),
          CollectionChapterRef(
            sourceKey: sourceKey,
            comicId: comicId,
            chapterId: chapterId,
          ),
        );
      }
    });
  });

  group('decode rejects foreign ids with null', () {
    test('null, empty and wrong version', () {
      expect(decodeCollectionChapterId(null), isNull);
      expect(decodeCollectionChapterId(''), isNull);
      expect(decodeCollectionChapterId('cx2:YWJj:ZA:ZQ'), isNull);
      expect(isCollectionChapterId(null), isFalse);
      expect(isCollectionChapterId(''), isFalse);
    });

    test('wrong segment count', () {
      expect(decodeCollectionChapterId('cx1:YWJj'), isNull);
      expect(decodeCollectionChapterId('cx1:YWJj:ZA:ZQ:extra'), isNull);
      expect(decodeCollectionChapterId('plain-chapter-id'), isNull);
    });

    test('malformed base64 segments', () {
      expect(decodeCollectionChapterId('cx1:!!!:ZA:ZQ'), isNull);
      expect(decodeCollectionChapterId('cx1:YWJj:###:ZQ'), isNull);
      expect(decodeCollectionChapterId('cx1:YWJj:ZA:???'), isNull);
    });

    test('empty source or comic address', () {
      final emptySource = encodeCollectionChapterId(
        sourceKey: '',
        comicId: 'c',
        chapterId: 'e',
      );
      final emptyComic = encodeCollectionChapterId(
        sourceKey: 's',
        comicId: '',
        chapterId: 'e',
      );
      expect(decodeCollectionChapterId(emptySource), isNull);
      expect(decodeCollectionChapterId(emptyComic), isNull);
      expect(isCollectionChapterId(emptySource), isFalse);
    });
  });

  group('CollectionChapterRef value semantics', () {
    test('equality, hashCode and toString', () {
      const a = CollectionChapterRef(
        sourceKey: 's',
        comicId: 'c',
        chapterId: 'e',
      );
      const b = CollectionChapterRef(
        sourceKey: 's',
        comicId: 'c',
        chapterId: 'e',
      );
      const c = CollectionChapterRef(
        sourceKey: 's',
        comicId: 'c',
        chapterId: 'other',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      expect(a == ('not a ref' as Object), isFalse);
      expect(a.toString(), contains('s'));
    });
  });

  group('collectionUpdateSortKey', () {
    test('zero-pads dates so string order is chronological', () {
      expect(
        collectionUpdateSortKey(
          '2026-9-1',
        ).compareTo(collectionUpdateSortKey('2026-10-1')),
        lessThan(0),
      );
      expect(collectionUpdateSortKey('2026-9-1'), '2026-09-01');
      expect(collectionUpdateSortKey('2026-10-1'), '2026-10-01');
    });

    test('already padded input is stable', () {
      expect(collectionUpdateSortKey('2026-09-01'), '2026-09-01');
    });

    test('non-dates pass through untouched', () {
      expect(collectionUpdateSortKey(''), '');
      expect(collectionUpdateSortKey('yesterday'), 'yesterday');
      expect(collectionUpdateSortKey('2026-09'), '2026-09');
    });
  });
}
