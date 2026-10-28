import 'dart:collection';
import 'dart:convert';

import 'package:venera_unified/foundation/log.dart';
import 'package:venera_unified/foundation/res.dart';

import 'source.dart';
import 'models.dart';
import 'types.dart';

import 'source_parser_context.dart';

class SourceSearchParser {
  const SourceSearchParser(this.context);
  final SourceParserContext context;

  SearchPageData? loadSearchData() {
    if (!context.checkExists("search")) return null;
    var options = <SearchOptions>[];
    for (var element in context.getValue("search.optionList") ?? []) {
      LinkedHashMap<String, String> map = LinkedHashMap<String, String>();
      for (var option in element["options"]) {
        if (option.isEmpty || !option.contains("-")) {
          continue;
        }
        var split = option.split("-");
        var key = split.removeAt(0);
        var value = split.join("-");
        map[key] = value;
      }
      options.add(
        SearchOptions(
          map,
          element["label"],
          element['type'] ?? 'select',
          element['default'] == null ? null : jsonEncode(element['default']),
        ),
      );
    }

    SearchFunction? loadPage;

    SearchNextFunction? loadNext;

    // 可选：书源实现的精确标签搜索（配合搜索层 `tag:` 语法）
    TagSearchFunction? tagSearch;
    if (context.checkExists('search.tagSearch')) {
      tagSearch = (tag, keyword, page, searchOption) async {
        try {
          return await context.runReadCodeToCompletion<Res<List<Comic>>>("""
          ${context.sourceExpression}.search.tagSearch(
            ${jsonEncode(tag)}, ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(page)})
        """, consume: (res) => context.parseComicListResult(res, 'maxPage'));
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return context.failureResult(e, s);
        }
      };
    }

    if (context.checkExists('search.load')) {
      loadPage = (keyword, page, searchOption) async {
        try {
          return await context.runReadCodeToCompletion<Res<List<Comic>>>("""
          ${context.sourceExpression}.search.load(
            ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(page)})
        """, consume: (res) => context.parseComicListResult(res, 'maxPage'));
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return context.failureResult(e, s);
        }
      };
    } else {
      loadNext = (keyword, next, searchOption) async {
        try {
          return await context.runReadCodeToCompletion<Res<List<Comic>>>("""
          ${context.sourceExpression}.search.loadNext(
            ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(next)})
        """, consume: (res) => context.parseComicListResult(res, 'next'));
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return context.failureResult(e, s);
        }
      };
    }

    return SearchPageData(options, loadPage, loadNext, tagSearch: tagSearch);
  }

  TagSuggestionSelectFunc? parseTagSuggestionSelectFunc() {
    if (!context.checkExists("search.onTagSuggestionSelected")) {
      return null;
    }
    return (namespace, tag) {
      return context.consumeSynchronous(
        () => context.runOwnedCode("""
          ${context.sourceExpression}.search.onTagSuggestionSelected(
            ${jsonEncode(namespace)}, ${jsonEncode(tag)})
        """),
        (res) => res is String ? res : "$namespace:$tag",
      );
    };
  }
}
