import 'dart:math';

import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/features/favorites/favorites_api.dart';
import 'package:venera_unified/features/favorites/favorites_manager.dart';
import 'package:venera_unified/features/history/history_manager.dart';
import 'package:venera_unified/features/history/history_model.dart';
import 'package:venera_unified/features/local_comics/local.dart';
import 'package:venera_unified/foundation/comic_type.dart';

/// Sources a random comic can be drawn from.
enum RandomComicSource { favorites, history, local }

/// Reading-progress filter applied before drawing.
enum RandomComicStatus { any, notStarted, inProgress, completed }

/// Bounded read access to one backing library.
///
/// The picker only ever calls [count] plus [readRange]; implementations must
/// not load the whole table to serve either method, so large libraries stay
/// cheap to draw from.
abstract class RandomComicDataSource {
  int count();

  /// Rows in stable order starting at [offset], at most [limit] rows.
  List<Comic> readRange(int offset, int limit);
}

/// Resolves reading progress for a candidate. Returns null when never read.
typedef RandomComicHistoryLookup = History? Function(String id, ComicType type);

/// Draws one random comic from a bounded data source.
///
/// Small libraries (at most [maxReads] rows) are read fully, so the draw is
/// exactly uniform. Large libraries are sampled through random windows: at
/// most [maxReads] rows are ever read, which keeps the draw O(1) in library
/// size at the cost of approximate uniformity under status filters.
abstract final class RandomComicPicker {
  static const int defaultMaxReads = 200;
  static const int defaultWindowSize = 25;

  static ComicType _typeOf(Comic comic) {
    if (comic is FavoriteItem) return comic.type;
    if (comic is LocalComic) return comic.comicType;
    if (comic is History) return comic.type;
    return ComicType.fromKey(comic.sourceKey);
  }

  static bool _completed(Comic comic, History history) {
    if (comic is LocalComic && comic.chapters != null) {
      return history.readEpisode.length >= comic.chapters!.length;
    }
    return history.maxPage != null && history.page >= history.maxPage!;
  }

  static bool matches(
    Comic comic,
    RandomComicStatus status, {
    RandomComicHistoryLookup? historyOf,
  }) {
    if (status == RandomComicStatus.any) return true;
    final History? history = comic is History
        ? comic
        : historyOf?.call(comic.id, _typeOf(comic));
    return switch (status) {
      RandomComicStatus.any => true,
      RandomComicStatus.notStarted => history == null,
      RandomComicStatus.completed =>
        history != null && _completed(comic, history),
      RandomComicStatus.inProgress =>
        history != null && !_completed(comic, history),
    };
  }

  static Comic? pick(
    RandomComicDataSource source, {
    RandomComicStatus status = RandomComicStatus.any,
    RandomComicHistoryLookup? historyOf,
    Random? random,
    int maxReads = defaultMaxReads,
    int windowSize = defaultWindowSize,
  }) {
    assert(maxReads > 0, 'maxReads must be positive');
    assert(windowSize > 0, 'windowSize must be positive');
    final total = source.count();
    if (total <= 0) return null;
    final rng = random ?? Random();
    final window = windowSize > total ? total : windowSize;
    // Small libraries: read everything so the draw stays exactly uniform.
    // Large libraries: probe random windows within the read budget.
    final budget = maxReads > total ? total : maxReads;
    final attempts = (budget + window - 1) ~/ window;
    final candidates = <Comic>{};
    for (var attempt = 0; attempt < attempts; attempt++) {
      final limit = attempt == attempts - 1 ? budget - attempt * window : window;
      if (limit <= 0) break;
      final offset = total == window
          ? 0
          : rng.nextInt(total - window + 1);
      final readLimit = limit > window ? window : limit;
      for (final comic in source.readRange(offset, readLimit)) {
        if (matches(comic, status, historyOf: historyOf)) {
          candidates.add(comic);
        }
      }
    }
    if (candidates.isEmpty) return null;
    final list = candidates.toList();
    return list[rng.nextInt(list.length)];
  }

  /// Live lookup against the app's history database.
  static History? liveHistoryOf(String id, ComicType type) {
    final manager = HistoryManager.cache;
    if (manager == null || !manager.isInitialized) return null;
    return manager.find(id, type);
  }
}

/// Favorites adapter: folders are concatenated in manager order.
class FavoritesRandomSource implements RandomComicDataSource {
  FavoritesRandomSource({LocalFavoritesManager? manager})
    : _manager = manager ?? LocalFavoritesManager();

  final LocalFavoritesManager _manager;
  List<String>? _folders;

  List<String> get _folderNames => _folders ??= _manager.folderNames;

  @override
  int count() {
    var total = 0;
    for (final folder in _folderNames) {
      total += _manager.count(folder);
    }
    return total;
  }

  @override
  List<Comic> readRange(int offset, int limit) {
    assert(offset >= 0 && limit >= 0);
    final result = <Comic>[];
    var skip = offset;
    var take = limit;
    for (final folder in _folderNames) {
      if (take <= 0) break;
      final folderCount = _manager.count(folder);
      if (skip >= folderCount) {
        skip -= folderCount;
        continue;
      }
      final rows = _manager.getFolderComics(
        folder,
        limit: take,
        offset: skip,
      );
      result.addAll(rows);
      take -= rows.length;
      skip = 0;
    }
    return result;
  }
}

/// History adapter: newest-first order, same as the history page.
class HistoryRandomSource implements RandomComicDataSource {
  HistoryRandomSource({HistoryManager? manager})
    : _manager = manager ?? HistoryManager();

  final HistoryManager _manager;

  @override
  int count() => _manager.count();

  @override
  List<Comic> readRange(int offset, int limit) =>
      _manager.readRange(offset, limit);
}

/// Local-library adapter: newest-first order.
class LocalRandomSource implements RandomComicDataSource {
  LocalRandomSource({LocalManager? manager})
    : _manager = manager ?? LocalManager();

  final LocalManager _manager;

  @override
  int count() => _manager.count;

  @override
  List<Comic> readRange(int offset, int limit) =>
      _manager.readRange(offset, limit);
}

/// Builds the live adapter for [source].
RandomComicDataSource randomComicDataSource(RandomComicSource source) {
  return switch (source) {
    RandomComicSource.favorites => FavoritesRandomSource(),
    RandomComicSource.history => HistoryRandomSource(),
    RandomComicSource.local => LocalRandomSource(),
  };
}
