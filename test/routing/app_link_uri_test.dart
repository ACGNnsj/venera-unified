import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/routing/app_link_uri.dart';
import 'package:venera_unified/routing/app_links.dart';
import 'package:venera_unified/features/comic_source/source.dart';
import '../support/comic_source_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sources = <ComicSource>[];
  setUp(
    () => configureComicSourceRegistry(
      all: () => sources,
      find: (key) => sources.where((s) => s.key == key).firstOrNull,
      fromIntKey: (_) => null,
      isEmpty: () => sources.isEmpty,
    ),
  );
  tearDown(sources.clear);

  test('custom links reject empty fields and ambiguous structures', () {
    for (final link in [
      'venera-unified://comic?id=&source=test',
      'venera-unified://comic?id=1&source=%20',
      'venera-unified://comic/extra?id=1&source=test',
      'venera-unified://c/test/1/extra',
      'venera-unified://c/test/',
      'venera-unified://user@comic?id=1&source=test',
      'venera-unified://comic:81?id=1&source=test',
    ]) {
      expect(parseComicFromUri(Uri.parse(link)), isNull, reason: link);
    }
  });

  test('webview links try later same-domain handlers after null or error', () {
    final calls = <String>[];
    for (final throws in [false, true]) {
      sources.clear();
      calls.clear();
      sources.addAll([
        _LinkSource(
          'first',
          LinkHandler(['match.test'], (_) {
            calls.add('first');
            if (throws) throw StateError('rejected');
            return null;
          }),
        ),
        _LinkSource(
          'second',
          LinkHandler(['match.test'], (_) {
            calls.add('second');
            return null;
          }),
        ),
      ]);
      expect(tryHandleComicLink(Uri.parse('https://match.test/book')), isFalse);
      expect(calls, ['first', 'second']);
    }
  });

  test(
    'async links use a later same-domain handler that recognizes the path',
    () async {
      sources.addAll([
        _LinkSource('first', LinkHandler(['match.test'], (_) => null)),
        _LinkSource('second', LinkHandler(['match.test'], (_) => 'book')),
      ]);
      expect(await handleAppLink(Uri.parse('https://match.test/book')), isTrue);
    },
  );

  test('web handlers never receive non-web URLs', () async {
    var calls = 0;
    sources.add(
      _LinkSource(
        'one',
        LinkHandler(['match.test'], (_) {
          calls++;
          return null;
        }),
      ),
    );
    for (final url in ['file://match.test/book', 'custom://match.test/book']) {
      expect(tryHandleComicLink(Uri.parse(url)), isFalse);
      expect(await handleAppLink(Uri.parse(url)), isFalse);
    }
    expect(calls, 0);
  });

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

class _LinkSource extends ComicSourceFixture {
  _LinkSource(String key, this._handler) : super(key: key);
  final LinkHandler _handler;
  @override
  LinkHandler get linkHandler => _handler;
}
