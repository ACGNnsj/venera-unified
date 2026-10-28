import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_source/comic_source.dart';
import 'package:venera_unified/features/search/search_query.dart';
import 'package:venera_unified/foundation/res.dart';

Comic _comic({
  String title = 'title',
  String? subtitle,
  List<String>? tags,
  String description = '',
}) {
  return Comic(
    title,
    '',
    'id-$title',
    subtitle,
    tags,
    description,
    'test',
    null,
    null,
  );
}

/// Canned source results whose tags hold categories only (like JM's
/// parseComic), never the real search tag.
List<Comic> _categoryOnlyComics() => [
  _comic(title: 'first', subtitle: 'authorA', tags: ['short']),
  _comic(title: 'second', subtitle: 'authorB', tags: ['serial']),
];

void main() {
  group('SearchQuery.parse tag: syntax (ported from lll)', () {
    test('pure tag search exposes firstTagFilter', () {
      final query = SearchQuery.parse('tag:fullcolor');
      expect(query.firstTagFilter, 'fullcolor');
      // cleanKeyword keeps the fallback semantic; pushdown uses plainKeyword.
      expect(query.cleanKeyword, 'tag:fullcolor');
      expect(query.hasFilters, isTrue);
      expect(query.fieldFilters, hasLength(1));
      expect(query.fieldFilters.first.key, 'tag');
    });

    test('tag plus keyword keeps the keyword for the source', () {
      final query = SearchQuery.parse('tag:fullcolor sister');
      expect(query.firstTagFilter, 'fullcolor');
      expect(query.cleanKeyword, 'sister');
    });

    test('multiple tags push the first down, rest stay client-side', () {
      final query = SearchQuery.parse('tag:fullcolor tag:married');
      expect(query.firstTagFilter, 'fullcolor');
      expect(query.fieldFilters, hasLength(2));
    });

    test('-tag is an exclude filter and never pushes down', () {
      final query = SearchQuery.parse('-tag:ntr sister');
      expect(query.firstTagFilter, isNull);
      expect(query.excludeFieldFilters, hasLength(1));
      expect(query.excludeFieldFilters.first.key, 'tag');
      expect(query.cleanKeyword, 'sister');
    });

    test('author is not a tag filter', () {
      final query = SearchQuery.parse('author:someone');
      expect(query.firstTagFilter, isNull);
      expect(query.fieldFilters.first.key, 'author');
    });

    test('plain search has zero overhead', () {
      final query = SearchQuery.parse('sister');
      expect(query.firstTagFilter, isNull);
      expect(query.hasFilters, isFalse);
      expect(query.cleanKeyword, 'sister');
    });

    test('tag value is lowercased', () {
      final query = SearchQuery.parse('tag:Vanilla');
      expect(query.firstTagFilter, 'vanilla');
    });

    test('pure tag leaves plainKeyword empty (no syntax leak)', () {
      final query = SearchQuery.parse('tag:fullcolor');
      expect(query.plainKeyword, '');
      expect(query.cleanKeyword, 'tag:fullcolor');
    });

    test('tag plus words keeps plainKeyword to plain words only', () {
      final query = SearchQuery.parse('tag:fullcolor sister -ntr');
      expect(query.plainKeyword, 'sister');
      expect(query.cleanKeyword, 'sister');
    });
  });

  group('SearchQuery.parse other syntax', () {
    test('exact phrase is kept whole and also sent to the source', () {
      final query = SearchQuery.parse('"sister brother"');
      expect(query.exactPhrases, ['sister brother']);
      expect(query.cleanKeyword, 'sister brother');
      expect(query.plainKeyword, 'sister brother');
    });

    test('-term becomes a full-text exclude', () {
      final query = SearchQuery.parse('sister -ntr');
      expect(query.excludes, ['ntr']);
      expect(query.cleanKeyword, 'sister');
    });

    test('unknown field falls back to a plain keyword', () {
      final query = SearchQuery.parse('status:ongoing');
      expect(query.hasFilters, isFalse);
      expect(query.cleanKeyword, 'status:ongoing');
      expect(query.plainKeyword, 'status:ongoing');
    });

    test('language filter passes through to the source verbatim', () {
      final query = SearchQuery.parse('sister language:zh');
      expect(query.hasFilters, isFalse);
      expect(query.cleanKeyword, 'sister language:zh');
    });

    test('tag with empty value is a plain keyword', () {
      final query = SearchQuery.parse('tag:');
      expect(query.hasFilters, isFalse);
      expect(query.cleanKeyword, 'tag:');
    });

    test('empty input parses to empty keywords without filters', () {
      final query = SearchQuery.parse('   ');
      expect(query.cleanKeyword, '');
      expect(query.plainKeyword, '');
      expect(query.hasFilters, isFalse);
    });
  });

  group('SearchQuery.matches and filterResult', () {
    test('tag include matches case-insensitively', () {
      final query = SearchQuery.parse('tag:SHORT');
      expect(query.matches(_comic(tags: ['short'])), isTrue);
      expect(query.matches(_comic(tags: ['serial'])), isFalse);
    });

    test('tag exclude rejects', () {
      final query = SearchQuery.parse('-tag:ntr');
      expect(query.matches(_comic(tags: ['ntr'])), isFalse);
      expect(query.matches(_comic(tags: ['vanilla'])), isTrue);
    });

    test('author matches subtitle or description', () {
      final query = SearchQuery.parse('author:authora');
      expect(query.matches(_comic(subtitle: 'authorA')), isTrue);
      expect(query.matches(_comic(description: 'by authorA here')), isTrue);
      expect(query.matches(_comic(subtitle: 'other')), isFalse);
    });

    test('excludes and exact phrases match the full-text blob', () {
      final query = SearchQuery.parse('-ntr "sister brother"');
      expect(query.matches(_comic(title: 'sister brother')), isTrue);
      expect(
        query.matches(_comic(title: 'sister brother', tags: ['ntr'])),
        isFalse,
      );
      expect(query.matches(_comic(title: 'sister')), isFalse);
    });

    test('stripFirstTagFilter drops only the first tag include', () {
      final query = SearchQuery.parse('tag:fullcolor tag:short -tag:ntr');
      final stripped = query.stripFirstTagFilter();
      expect(stripped.firstTagFilter, 'short');
      expect(stripped.excludeFieldFilters, hasLength(1));
      // Original is untouched.
      expect(query.firstTagFilter, 'fullcolor');
    });

    test('filterResult without filters returns the same instance', () {
      final query = SearchQuery.parse('sister');
      final res = Res(_categoryOnlyComics(), subData: 3);
      expect(identical(query.filterResult(res), res), isTrue);
    });

    test('filterResult passes errors through untouched', () {
      final query = SearchQuery.parse('tag:short');
      final res = Res<List<Comic>>.error('boom');
      expect(identical(query.filterResult(res), res), isTrue);
    });

    test('filterResult keeps matches and subData', () {
      final query = SearchQuery.parse('tag:short');
      final res = Res(_categoryOnlyComics(), subData: 3);
      final filtered = query.filterResult(res);
      expect(filtered.data, hasLength(1));
      expect(filtered.data.single.title, 'first');
      expect(filtered.subData, 3);
    });
  });

  group('tagSearch pushdown pipeline (fake bridge)', () {
    test('pushed tag uses plainKeyword and strips before filtering', () async {
      final calls = <List<Object?>>[];
      Future<Res<List<Comic>>> fakeTagSearch(
        String tag,
        String keyword,
        int page,
        List<String> searchOption,
      ) async {
        calls.add([tag, keyword, page, searchOption]);
        return Res(_categoryOnlyComics(), subData: 1);
      }

      // Same branch logic as SearchResultPage.loadPage.
      final query = SearchQuery.parse('sister tag:fullcolor');
      final tag = query.firstTagFilter!;
      final res = await fakeTagSearch(tag, query.plainKeyword, 1, ['mr']);
      expect(calls.single, [
        'fullcolor',
        'sister',
        1,
        ['mr'],
      ]);

      // Bug repro: filtering without stripping empties server-side hits,
      // because result tags hold categories only.
      expect(query.filterResult(res).data, isEmpty);

      // Fixed pipeline: strip the pushed tag, keep the rest.
      final fixed = query.stripFirstTagFilter().filterResult(res);
      expect(fixed.data, hasLength(2));
      expect(fixed.subData, 1);
    });

    test('remaining tags still filter client-side after pushdown', () async {
      Future<Res<List<Comic>>> fakeTagSearch(
        String tag,
        String keyword,
        int page,
        List<String> searchOption,
      ) async {
        return Res(_categoryOnlyComics(), subData: 1);
      }

      final query = SearchQuery.parse('tag:fullcolor tag:short');
      final res = await fakeTagSearch(
        query.firstTagFilter!,
        query.plainKeyword,
        1,
        const [],
      );
      final result = query.stripFirstTagFilter().filterResult(res);
      expect(result.data, hasLength(1));
      expect(result.data.single.tags, contains('short'));
    });

    test('sources without tagSearch fall back to cleanKeyword', () async {
      String? received;
      Future<Res<List<Comic>>> fakeLoadPage(
        String keyword,
        int page,
        List<String> searchOption,
      ) async {
        received = keyword;
        return Res(_categoryOnlyComics());
      }

      final query = SearchQuery.parse('tag:fullcolor');
      final res = await fakeLoadPage(query.cleanKeyword, 1, const []);
      // Fallback semantic: the raw text is still sent to the source.
      expect(received, 'tag:fullcolor');
      // Client-side filter then applies to the returned comics.
      expect(query.filterResult(res).data, isEmpty);
    });

    test('loadNext path uses cleanKeyword', () async {
      String? received;
      Future<Res<List<Comic>>> fakeLoadNext(
        String keyword,
        String? next,
        List<String> searchOption,
      ) async {
        received = keyword;
        return Res(_categoryOnlyComics());
      }

      final query = SearchQuery.parse('sister tag:fullcolor');
      await fakeLoadNext(query.cleanKeyword, null, const []);
      expect(received, 'sister');
    });
  });
}
