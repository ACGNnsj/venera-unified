import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_collection/comic_collection_store.dart';
import 'package:venera_unified/features/comic_collection/comic_collections_page.dart';

ComicCollection _collection({
  required String id,
  required String name,
  List<CollectionMember> members = const [],
  DateTime? createdAt,
}) => ComicCollection(
  id: id,
  sourceKey: 'comic_collection_$id',
  name: name,
  members: members,
  createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
);

CollectionMember _member({
  String sourceKey = 'jm',
  required String comicId,
  String displayName = '',
  String cachedTitle = '',
}) => CollectionMember(
  sourceKey: sourceKey,
  comicId: comicId,
  displayName: displayName,
  cachedTitle: cachedTitle,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('filterCollections', () {
    test('empty keyword returns every collection in order', () {
      final input = [
        _collection(id: 'a', name: 'Alpha'),
        _collection(id: 'b', name: 'Beta'),
      ];

      final result = filterCollections(input, '  ');

      expect(result.map((c) => c.id), ['a', 'b']);
    });

    test('matches the collection name case-insensitively', () {
      final input = [
        _collection(id: 'a', name: 'Alpha Story'),
        _collection(id: 'b', name: 'Beta Story'),
      ];

      expect(filterCollections(input, 'ALPHA').map((c) => c.id), ['a']);
    });

    test('matches a member label', () {
      final input = [
        _collection(
          id: 'a',
          name: 'Alpha',
          members: [_member(comicId: '1', cachedTitle: 'Volume Three')],
        ),
        _collection(id: 'b', name: 'Beta'),
      ];

      expect(filterCollections(input, 'three').map((c) => c.id), ['a']);
    });

    test('matches a member display name over its cached title', () {
      final input = [
        _collection(
          id: 'a',
          name: 'Alpha',
          members: [
            _member(comicId: '1', displayName: 'Prologue', cachedTitle: 'Ch 0'),
          ],
        ),
      ];

      expect(filterCollections(input, 'prologue').map((c) => c.id), ['a']);
      expect(filterCollections(input, 'ch 0'), isEmpty);
    });

    test('returns empty when nothing matches', () {
      final input = [_collection(id: 'a', name: 'Alpha')];

      expect(filterCollections(input, 'zzz'), isEmpty);
    });
  });

  group('sortCollections', () {
    test('name sorts case-insensitively ascending', () {
      final list = [
        _collection(id: 'b', name: 'beta'),
        _collection(id: 'a', name: 'Alpha'),
        _collection(id: 'c', name: 'Gamma'),
      ];

      sortCollections(list, 'name');

      expect(list.map((c) => c.id), ['a', 'b', 'c']);
    });

    test('count sorts by member count descending', () {
      final list = [
        _collection(
          id: 'one',
          name: 'One',
          members: [_member(comicId: '1')],
        ),
        _collection(
          id: 'three',
          name: 'Three',
          members: [
            _member(comicId: '1'),
            _member(comicId: '2'),
            _member(comicId: '3'),
          ],
        ),
        _collection(id: 'zero', name: 'Zero'),
      ];

      sortCollections(list, 'count');

      expect(list.map((c) => c.id), ['three', 'one', 'zero']);
    });

    test('created sorts newest first', () {
      final list = [
        _collection(
          id: 'old',
          name: 'Old',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
        _collection(
          id: 'new',
          name: 'New',
          createdAt: DateTime.fromMillisecondsSinceEpoch(3000),
        ),
        _collection(
          id: 'mid',
          name: 'Mid',
          createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
        ),
      ];

      sortCollections(list, 'created');

      expect(list.map((c) => c.id), ['new', 'mid', 'old']);
    });

    test('manual keeps the store order untouched', () {
      final list = [
        _collection(id: 'b', name: 'Beta'),
        _collection(id: 'a', name: 'Alpha'),
      ];

      sortCollections(list, 'manual');

      expect(list.map((c) => c.id), ['b', 'a']);
    });
  });
}
