import 'dart:convert';

import 'package:venera_unified/foundation/appdata.dart';

/// A single detailed search-history record, ported from venera-prime's
/// `SearchHistoryEntry` (lib/foundation/search_history.dart).
///
/// Unified adaptation: only concrete source searches are recorded, so
/// [sourceKey] is always a real source key; the prime `labels`/`schema`
/// tag-suggestion fields are dropped because unified filter state is fully
/// captured by [options]. The keyword-only [Appdata.searchHistory] list is
/// kept as the legacy (old-mode) view of the same searches.
class SearchHistoryEntry {
  final String keyword;
  final String sourceKey;
  final String sourceName;
  final List<String> options;
  final int page;

  const SearchHistoryEntry({
    required this.keyword,
    required this.sourceKey,
    this.sourceName = '',
    this.options = const [],
    this.page = 1,
  });

  String get identity => jsonEncode([keyword, sourceKey, options]);

  SearchHistoryEntry atPage(int value) => SearchHistoryEntry(
    keyword: keyword,
    sourceKey: sourceKey,
    sourceName: sourceName,
    options: options,
    page: value,
  );

  Map<String, dynamic> toJson() => {
    'keyword': keyword,
    'source': sourceKey,
    'name': sourceName,
    'options': options,
    'page': page,
  };

  static SearchHistoryEntry? fromJson(dynamic value) {
    if (value is! Map) return null;
    final word = value['keyword'];
    final source = value['source'];
    final name = value['name'];
    final options = value['options'];
    final page = value['page'];
    bool validList(dynamic v) =>
        v is List &&
        v.length <= 64 &&
        v.every((e) => e is String && e.length <= 4096);
    if (word is! String ||
        word.trim().isEmpty ||
        word.length > 4096 ||
        source is! String ||
        source.isEmpty ||
        source.length > 512 ||
        name is! String ||
        name.length > 512 ||
        !validList(options) ||
        page is! int ||
        page < 1 ||
        page > 1000000) {
      return null;
    }
    return SearchHistoryEntry(
      keyword: word,
      sourceKey: source,
      sourceName: name,
      options: List<String>.from(options),
      page: page,
    );
  }

  /// Decode a persisted entry list, tolerating the JSON-string form used by
  /// [encodeList] as well as raw maps. Invalid items are skipped, identity
  /// duplicates collapse, and the result is capped at 50, newest first.
  static List<SearchHistoryEntry> decodeList(dynamic value) {
    if (value is! List) return [];
    final result = <SearchHistoryEntry>[];
    final ids = <String>{};
    for (final item in value) {
      dynamic decoded = item;
      if (decoded is String) {
        try {
          decoded = jsonDecode(decoded);
        } catch (_) {
          continue;
        }
      }
      final entry = fromJson(decoded);
      if (entry != null && ids.add(entry.identity)) result.add(entry);
      if (result.length == 50) break;
    }
    return result;
  }

  static List<String> encodeList(List<SearchHistoryEntry> entries) =>
      entries.map((e) => jsonEncode(e.toJson())).toList();

  /// Read the persisted detailed-history records (newest first).
  static List<SearchHistoryEntry> readStored() =>
      decodeList(appdata.settings['searchHistoryEntries']);

  static Future<void> writeStored(List<SearchHistoryEntry> entries) =>
      appdata.updateSettings((settings) {
        settings['searchHistoryEntries'] = encodeList(entries);
      });
}

/// Remember one detailed search record (new history mode) and keep the legacy
/// keyword history in sync. Restart-persisted via app settings.
Future<void> rememberSearchHistoryEntry(SearchHistoryEntry entry) {
  final entries = SearchHistoryEntry.readStored()
    ..removeWhere((e) => e.identity == entry.identity);
  entries.insert(0, entry);
  if (entries.length > 50) entries.removeRange(50, entries.length);
  return SearchHistoryEntry.writeStored(entries)
      .then((_) => appdata.addSearchHistory(entry.keyword));
}

/// Update the saved page of one record (identified by [identity]).
Future<void> updateSearchHistoryEntryPage(String identity, int page) {
  final entries = SearchHistoryEntry.readStored();
  final index = entries.indexWhere((e) => e.identity == identity);
  if (index < 0) return Future.value();
  entries[index] = entries[index].atPage(page);
  return SearchHistoryEntry.writeStored(entries);
}

/// Remove one record; drop its keyword from the legacy history only when no
/// other record references it (mirrors venera-prime).
Future<void> removeSearchHistoryEntry(SearchHistoryEntry entry) {
  final entries = SearchHistoryEntry.readStored()
    ..removeWhere((e) => e.identity == entry.identity);
  return SearchHistoryEntry.writeStored(entries).then((_) async {
    if (!SearchHistoryEntry.readStored()
        .any((e) => e.keyword == entry.keyword)) {
      await appdata.removeSearchHistory(entry.keyword);
    }
  });
}

/// Clear all detailed records (used together with [Appdata.clearSearchHistory]).
Future<void> clearSearchHistoryEntries() =>
    SearchHistoryEntry.writeStored(const []);

/// Read the persisted detailed-history records (newest first).
List<SearchHistoryEntry> readSearchHistoryEntries() =>
    SearchHistoryEntry.readStored();
