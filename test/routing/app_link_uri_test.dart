import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/routing/app_link_uri.dart';

void main() {
  group('parseComicFromUri', () {
    test('comic shape with title', () {
      final comic = parseComicFromUri(
        Uri.parse('venera-unified://comic?id=123&source=jm&title=abc'),
      );
      expect(comic, isNotNull);
      expect(comic!.id, '123');
      expect(comic.sourceKey, 'jm');
      expect(comic.title, 'abc');
    });

    test('comic shape without title', () {
      final comic = parseComicFromUri(
        Uri.parse('venera-unified://comic?id=123&source=jm'),
      );
      expect(comic, isNotNull);
      expect(comic!.id, '123');
      expect(comic.sourceKey, 'jm');
      expect(comic.title, isNull);
    });

    test('short c shape', () {
      final comic = parseComicFromUri(Uri.parse('venera-unified://c/jm/123'));
      expect(comic, isNotNull);
      expect(comic!.id, '123');
      expect(comic.sourceKey, 'jm');
      expect(comic.title, isNull);
    });

    test('rejects legacy venera scheme', () {
      expect(
        parseComicFromUri(Uri.parse('venera://comic?id=123&source=jm')),
        isNull,
      );
      expect(parseComicFromUri(Uri.parse('venera://c/jm/123')), isNull);
    });

    test('rejects https and unknown hosts', () {
      expect(parseComicFromUri(Uri.parse('https://example.com/g/1')), isNull);
      expect(
        parseComicFromUri(Uri.parse('venera-unified://other?id=1')),
        isNull,
      );
    });

    test('rejects missing params and short paths', () {
      expect(
        parseComicFromUri(Uri.parse('venera-unified://comic?id=123')),
        isNull,
      );
      expect(
        parseComicFromUri(Uri.parse('venera-unified://comic?source=jm')),
        isNull,
      );
      expect(parseComicFromUri(Uri.parse('venera-unified://c/jm')), isNull);
    });
  });

  group('parseAppLink', () {
    test('finds link inside surrounding text', () {
      final uri = parseAppLink(
        '看看这个 venera-unified://comic?id=123&source=jm 很不错',
      );
      expect(uri, isNotNull);
      expect(uri!.scheme, appLinkScheme);
      expect(parseComicFromUri(uri)!.id, '123');
    });

    test('returns null when no link present', () {
      expect(parseAppLink('just some text'), isNull);
      expect(parseAppLink('venera://comic?id=123&source=jm'), isNull);
    });
  });

  group('buildComicUri round-trip', () {
    test('with title', () {
      final uri = buildComicUri(id: '123', sourceKey: 'jm', title: 'abc');
      expect(uri.scheme, appLinkScheme);
      final comic = parseComicFromUri(uri);
      expect(comic, isNotNull);
      expect(comic!.id, '123');
      expect(comic.sourceKey, 'jm');
      expect(comic.title, 'abc');
    });

    test('without title', () {
      final uri = buildComicUri(id: '123', sourceKey: 'jm');
      final comic = parseComicFromUri(uri);
      expect(comic, isNotNull);
      expect(comic!.id, '123');
      expect(comic.sourceKey, 'jm');
      expect(comic.title, isNull);
    });
  });
}
