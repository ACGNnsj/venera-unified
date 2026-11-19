/// Chapter ordering and duplicate-hiding ported from venera-prime.
///
/// ponytail: global order only, no per-comic override. Prime remembers one
/// order per comic; this port keeps a single global default because
/// ComicChaptersView never receives the comic id. Add per-comic storage
/// when a caller actually needs it.
///
/// ponytail: prime ChapterSequence (last-chapter lookup) is skipped;
/// unified history already tracks the reading position.
library;

/// Compares names the way people expect numbered files to sort.
int naturalCompare(String left, String right) {
  final leftList = RegExp(
    r'([0-9]+|[^0-9]+)',
  ).allMatches(left).map((m) => m.group(0)!).toList();
  final rightList = RegExp(
    r'([0-9]+|[^0-9]+)',
  ).allMatches(right).map((m) => m.group(0)!).toList();
  final length = leftList.length < rightList.length
      ? leftList.length
      : rightList.length;
  for (var i = 0; i < length; i++) {
    final a = leftList[i];
    final b = rightList[i];
    final aNumber = int.tryParse(a);
    final bNumber = int.tryParse(b);
    final result = aNumber != null && bNumber != null
        ? aNumber.compareTo(bNumber)
        : a.toLowerCase().compareTo(b.toLowerCase());
    if (result != 0) return result;
  }
  return left.length.compareTo(right.length);
}

/// Display order for chapter lists. Stored as [name] in settings.
enum ChapterOrder {
  source,
  reverse,
  titleAscending,
  titleDescending;

  /// Reorder raw indexes only; chapter IDs and stored history never change.
  List<int> apply(List<int> indexes, List<String> titles) {
    final result = indexes.toList();
    if (this == source) return result;
    if (this == reverse) return result.reversed.toList();
    final names = titles.toList();
    result.sort((a, b) {
      final compared = naturalCompare(names[a], names[b]);
      if (compared == 0) return a.compareTo(b);
      return this == titleDescending ? -compared : compared;
    });
    return result;
  }

  /// Merges the saved choice with the legacy [reverseChapterOrder] bool.
  static ChapterOrder resolve(String? saved, {required bool legacyReverse}) {
    switch (saved) {
      case 'reverse':
        return ChapterOrder.reverse;
      case 'titleAscending':
        return ChapterOrder.titleAscending;
      case 'titleDescending':
        return ChapterOrder.titleDescending;
      default:
        return legacyReverse ? ChapterOrder.reverse : ChapterOrder.source;
    }
  }
}

/// Hides same-id, same-title repeats some sources pad directories with.
abstract final class ChapterVisibility {
  static String _normalize(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static bool _isDuplicate(Set<String> seen, String id, String title) {
    return !seen.add('$id\u0000${_normalize(title)}');
  }

  /// Source indexes in display order for one flat chapter list.
  static List<int> display({
    required ChapterOrder order,
    required List<String> ids,
    required List<String> titles,
    required bool hideDuplicates,
  }) {
    final seen = <String>{};
    final visible = <int>[
      for (var i = 0; i < ids.length; i++)
        if (!hideDuplicates || !_isDuplicate(seen, ids[i], titles[i])) i,
    ];
    return order.apply(visible, titles);
  }
}
