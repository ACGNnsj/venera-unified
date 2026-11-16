import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/search/search_history_entry.dart';

SearchHistoryEntry entryOf(String keyword, {String source = 's1'}) =>
    SearchHistoryEntry(
      keyword: keyword,
      sourceKey: source,
      sourceName: 'Source',
      options: const ['a'],
      page: 2,
    );

void main() {
  test('fromJson accepts a valid record and rejects bad input', () {
    final entry = SearchHistoryEntry.fromJson({
      'keyword': 'k',
      'source': 's',
      'name': 'n',
      'options': ['x'],
      'page': 3,
    });
    expect(entry, isNotNull);
    expect(entry!.page, 3);
    expect(SearchHistoryEntry.fromJson(null), isNull);
    expect(SearchHistoryEntry.fromJson('k'), isNull);
    expect(
      SearchHistoryEntry.fromJson({
        'keyword': '   ',
        'source': 's',
        'name': '',
        'options': [],
        'page': 1,
      }),
      isNull,
    );
    // Empty source keys belong to legacy keyword history, not entries.
    expect(
      SearchHistoryEntry.fromJson({
        'keyword': 'k',
        'source': '',
        'name': '',
        'options': [],
        'page': 1,
      }),
      isNull,
    );
    expect(
      SearchHistoryEntry.fromJson({
        'keyword': 'k',
        'source': 's',
        'name': '',
        'options': [],
        'page': 0,
      }),
      isNull,
    );
  });

  test('decodeList skips invalid items, dedupes, and caps at 50', () {
    final items = [
      jsonEncode(entryOf('a').toJson()),
      entryOf('a').toJson(), // duplicate identity, kept once
      'not json',
      {'keyword': 'b', 'source': 's', 'name': '', 'options': [], 'page': 1},
      for (var i = 0; i < 60; i++)
        jsonEncode(entryOf('k$i', source: 's$i').toJson()),
    ];
    final decoded = SearchHistoryEntry.decodeList(items);
    expect(decoded, hasLength(50));
    expect(decoded.first.keyword, 'a');
    expect(SearchHistoryEntry.decodeList('nope'), isEmpty);
    expect(SearchHistoryEntry.decodeList(null), isEmpty);
  });

  test('atPage keeps identity fields and encodeList round-trips', () {
    final entry = entryOf('a').atPage(5);
    expect(entry.page, 5);
    expect(entry.identity, entryOf('a').identity);
    final roundTripped = SearchHistoryEntry.decodeList(
      SearchHistoryEntry.encodeList([entry]),
    );
    expect(roundTripped, hasLength(1));
    expect(roundTripped.single.page, 5);
  });
}
