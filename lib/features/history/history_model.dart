import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/history_contract.dart';
import 'package:venera_next/foundation/translations.dart';

class History implements Comic {
  HistoryType type;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  /// Last read names remain available when the source or chapter list is gone.
  String? chapterTitle;
  String? groupTitle;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  /// Last known chapter count, relative to [group] just like [ep].
  int? maxChapter;

  /// Cumulative foreground reading time for this comic.
  int readDurationMs;

  History({
    required this.type,
    required this.time,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.ep,
    required this.page,
    required this.id,
    required this.readEpisode,
    required this.maxPage,
    required this.readDurationMs,
    this.group,
    this.chapterTitle,
    this.groupTitle,
    this.maxChapter,
  });

  /// Detached values for a submitted storage operation, including read keys.
  History copy() => History(
    type: type,
    time: time,
    title: title,
    subtitle: subtitle,
    cover: cover,
    ep: ep,
    page: page,
    id: id,
    readEpisode: Set.of(readEpisode),
    maxPage: maxPage,
    maxChapter: maxChapter,
    readDurationMs: readDurationMs,
    group: group,
    chapterTitle: chapterTitle,
    groupTitle: groupTitle,
  );

  History.fromModel({
    required HistoryMixin model,
    required this.ep,
    required this.page,
    this.group,
    Set<String>? readChapters,
    DateTime? time,
    this.readDurationMs = 0,
  }) : type = model.historyType,
       title = model.title,
       subtitle = model.subTitle ?? '',
       cover = model.cover,
       id = model.id,
       readEpisode = readChapters ?? <String>{},
       time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
    : type = HistoryType(map["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
      title = map["title"],
      subtitle = map["subtitle"],
      cover = map["cover"],
      ep = map["ep"],
      page = map["page"],
      id = map["id"],
      readEpisode = Set<String>.from(
        (map["readEpisode"] as List<dynamic>?)?.toSet() ?? const <String>{},
      ),
      maxPage = map["max_page"],
      maxChapter = map['max_chapter'] as int?,
      group = map['chapter_group'] as int?,
      chapterTitle = map['chapter_title'] as String?,
      groupTitle = map['group_title'] as String?,
      readDurationMs = (map["read_duration_ms"] as num?)?.round() ?? 0;

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  @override
  bool operator ==(Object other) {
    return other is History && type == other.type && id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, type);

  @override
  String get description => progressDescription();

  /// Format saved coordinates only, omitting missing or inconsistent totals.
  String progressDescription({bool showTotals = false, bool compact = false}) {
    String number(int current, int? total) =>
        showTotals && total != null && total > 0 && total >= current
        ? '$current${compact ? '/' : ' / '}$total'
        : '$current';

    final parts = <String>[];
    if (!compact && (groupTitle?.trim().isNotEmpty == true || group != null)) {
      parts.add(
        groupTitle?.trim().isNotEmpty == true
            ? groupTitle!.trim()
            : "Group @group".tlParams({"group": group!}),
      );
    }
    final chapter = ep >= 1
        ? (compact ? 'Ch. @ep' : 'Chapter @ep').tlParams({
            'ep': number(ep, maxChapter),
          })
        : null;
    if (!showTotals && !compact && chapterTitle?.trim().isNotEmpty == true) {
      parts.add(chapterTitle!.trim());
    } else if (chapter != null) {
      parts.add(chapter);
    }
    if (page >= 1) {
      parts.add(
        (compact ? 'P. @page' : 'Page @page').tlParams({
          'page': number(page, maxPage),
        }),
      );
    }
    return parts.join(compact ? '\n' : ' - ');
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}
