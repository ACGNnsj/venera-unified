import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/features/favorites/favorites.dart';
import 'package:venera_unified/features/history/history.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/comic_type.dart';
import 'package:venera_unified/foundation/opencc.dart';
import 'package:venera_unified/foundation/res.dart';

enum SourceMigrationTaskStatus {
  running,
  waitingConfirmation,
  completed,
  canceled,
  failed,
}

class SourceMigrationTaskDetail {
  SourceMigrationTaskDetail({
    required this.source,
    this.target,
    this.status = 'pending',
    this.error,
  });

  final FavoriteItem source;
  FavoriteItem? target;
  String status;
  String? error;

  Map<String, dynamic> toJson() => {
    'source': source.toJson(),
    'target': target?.toJson(),
    'status': status,
    'error': error,
  };

  factory SourceMigrationTaskDetail.fromJson(Map<String, dynamic> json) {
    return SourceMigrationTaskDetail(
      source: FavoriteItem.fromJson(Map<String, dynamic>.from(json['source'])),
      target: json['target'] is Map
          ? FavoriteItem.fromJson(Map<String, dynamic>.from(json['target']))
          : null,
      status: json['status'] ?? 'pending',
      error: json['error'],
    );
  }
}

class SourceMigrationTask {
  SourceMigrationTask({
    required this.id,
    required this.folder,
    required this.targetSourceKeys,
    required this.targetSourceNames,
    required this.createdAt,
    required this.details,
    required this.migrateHistory,
    required this.replaceFavorite,
    required this.confirmEach,
    this.status = SourceMigrationTaskStatus.running,
    this.total = 0,
    this.checked = 0,
    this.migrated = 0,
    this.failed = 0,
    this.currentIndex = 0,
    this.finishedAt,
  });

  final String id;
  final String folder;
  final List<String> targetSourceKeys;
  final List<String> targetSourceNames;
  final DateTime createdAt;
  final List<SourceMigrationTaskDetail> details;
  final bool migrateHistory;
  final bool replaceFavorite;
  final bool confirmEach;
  SourceMigrationTaskStatus status;
  int total;
  int checked;
  int migrated;
  int failed;
  int currentIndex;
  DateTime? finishedAt;

  bool get isRunning => status == SourceMigrationTaskStatus.running;
  bool get isWaitingConfirmation =>
      status == SourceMigrationTaskStatus.waitingConfirmation;
  bool get isActive => isRunning || isWaitingConfirmation;
  double get progress => total == 0 ? 0 : checked / total;
  String get targetSourceKey =>
      targetSourceKeys.isEmpty ? '' : targetSourceKeys.first;
  String get targetSourceName {
    if (targetSourceNames.isNotEmpty) {
      return targetSourceNames.join(', ');
    }
    return targetSourceKeys
        .map((sourceKey) => ComicSource.find(sourceKey)?.name ?? sourceKey)
        .join(', ');
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'folder': folder,
    'targetSourceKeys': targetSourceKeys,
    'targetSourceNames': targetSourceNames,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'status': status.name,
    'migrateHistory': migrateHistory,
    'replaceFavorite': replaceFavorite,
    'confirmEach': confirmEach,
    'total': total,
    'checked': checked,
    'migrated': migrated,
    'failed': failed,
    'currentIndex': currentIndex,
    'details': details.map((detail) => detail.toJson()).toList(),
  };

  factory SourceMigrationTask.fromJson(Map<String, dynamic> json) {
    return SourceMigrationTask(
      id: json['id'] ?? '',
      folder: json['folder'] ?? '',
      targetSourceKeys:
          (json['targetSourceKeys'] as List?)?.whereType<String>().toList() ??
          [if (json['targetSourceKey'] is String) json['targetSourceKey']],
      targetSourceNames:
          (json['targetSourceNames'] as List?)?.whereType<String>().toList() ??
          [if (json['targetSourceName'] is String) json['targetSourceName']],
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] ?? ''),
      status: SourceMigrationTaskStatus.values.firstWhere(
        (status) => status.name == json['status'],
        orElse: () => SourceMigrationTaskStatus.completed,
      ),
      migrateHistory: json['migrateHistory'] ?? true,
      replaceFavorite: json['replaceFavorite'] ?? true,
      confirmEach: json['confirmEach'] ?? false,
      total: json['total'] ?? 0,
      checked: json['checked'] ?? 0,
      migrated: json['migrated'] ?? 0,
      failed: json['failed'] ?? 0,
      currentIndex: json['currentIndex'] ?? 0,
      details:
          (json['details'] as List?)?.whereType<Map>().map((item) {
            return SourceMigrationTaskDetail.fromJson(
              Map<String, dynamic>.from(item),
            );
          }).toList() ??
          const <SourceMigrationTaskDetail>[],
    );
  }
}

class SourceMigrationTaskManager with ChangeNotifier {
  SourceMigrationTaskManager._() {
    _load();
    Future.microtask(_resumeRunningTasks);
  }

  static final SourceMigrationTaskManager instance =
      SourceMigrationTaskManager._();

  final currentTasks = <SourceMigrationTask>[];
  final historyTasks = <SourceMigrationTask>[];
  final _runningIds = <String>{};
  final _canceledIds = <String>{};

  SourceMigrationTask startBatch({
    required String folder,
    required List<FavoriteItem> favorites,
    required List<String> targetSourceKeys,
    required bool migrateHistory,
    required bool replaceFavorite,
    required bool confirmEach,
  }) {
    final distinctTargetSourceKeys = targetSourceKeys.toSet().toList();
    if (distinctTargetSourceKeys.isEmpty) {
      throw 'No target sources selected';
    }
    final targetSourceNames = distinctTargetSourceKeys.map((sourceKey) {
      return ComicSource.find(sourceKey)?.name ?? sourceKey;
    }).toList();
    final task = SourceMigrationTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      folder: folder,
      targetSourceKeys: distinctTargetSourceKeys,
      targetSourceNames: targetSourceNames,
      createdAt: DateTime.now(),
      details: favorites.map((favorite) {
        return SourceMigrationTaskDetail(source: favorite);
      }).toList(),
      migrateHistory: migrateHistory,
      replaceFavorite: replaceFavorite,
      confirmEach: confirmEach,
      total: favorites.length,
    );
    currentTasks.insert(0, task);
    _saveActive();
    notifyListeners();
    unawaited(_run(task));
    return task;
  }

  Future<void> migrateSingle({
    required FavoriteItem source,
    required FavoriteItem target,
    required bool migrateHistory,
    required bool replaceFavorite,
  }) async {
    await _applyMigration(
      source: source,
      target: target,
      migrateHistory: migrateHistory,
      replaceFavorite: replaceFavorite,
    );
  }

  void cancel(String id) {
    final task = _activeTask(id);
    if (task == null) {
      return;
    }
    if (task.isWaitingConfirmation) {
      task.status = SourceMigrationTaskStatus.canceled;
      _finish(task);
      notifyListeners();
      return;
    }
    _canceledIds.add(id);
    notifyListeners();
  }

  Future<void> confirm(String id, int index) async {
    final task = _activeTask(id);
    if (task == null || index < 0 || index >= task.details.length) {
      return;
    }
    final detail = task.details[index];
    final target = detail.target;
    if (target == null || detail.status != 'matched') {
      return;
    }
    try {
      await _applyMigration(
        source: detail.source,
        target: target,
        migrateHistory: task.migrateHistory,
        replaceFavorite: task.replaceFavorite,
      );
      detail.status = 'migrated';
      task.migrated++;
    } catch (e) {
      detail.status = 'failed';
      detail.error = e.toString();
      task.failed++;
    }
    _completeWaitingTaskIfReady(task);
    _saveActive();
    notifyListeners();
  }

  Future<void> confirmAll(String id) async {
    final task = _activeTask(id);
    if (task == null) {
      return;
    }
    for (var i = 0; i < task.details.length; i++) {
      if (_activeTask(id) == null) {
        return;
      }
      await confirm(id, i);
    }
  }

  Future<void> _run(SourceMigrationTask task) async {
    if (!_runningIds.add(task.id)) {
      return;
    }
    try {
      while (task.currentIndex < task.details.length) {
        if (_canceledIds.contains(task.id)) {
          task.status = SourceMigrationTaskStatus.canceled;
          break;
        }
        final detail = task.details[task.currentIndex];
        await _matchAndMaybeMigrate(task, detail);
        task.checked++;
        task.currentIndex++;
        _saveActive();
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 650));
      }
      if (task.status == SourceMigrationTaskStatus.running) {
        task.status = task.confirmEach
            ? SourceMigrationTaskStatus.waitingConfirmation
            : SourceMigrationTaskStatus.completed;
      }
      if (!task.isWaitingConfirmation) {
        _finish(task);
      } else {
        _saveActive();
      }
    } catch (e) {
      task.status = SourceMigrationTaskStatus.failed;
      final detail = task.currentIndex < task.details.length
          ? task.details[task.currentIndex]
          : null;
      detail?.error = e.toString();
      detail?.status = 'failed';
      _finish(task);
    } finally {
      _runningIds.remove(task.id);
      _canceledIds.remove(task.id);
      notifyListeners();
    }
  }

  Future<void> _matchAndMaybeMigrate(
    SourceMigrationTask task,
    SourceMigrationTaskDetail detail,
  ) async {
    final errors = <String>[];
    FavoriteItem? target;
    for (final sourceKey in task.targetSourceKeys) {
      if (detail.source.sourceKey == sourceKey) {
        continue;
      }
      try {
        target = await _findMatch(detail.source, sourceKey);
      } catch (e) {
        errors.add('${ComicSource.find(sourceKey)?.name ?? sourceKey}: $e');
      }
      if (target != null) {
        break;
      }
    }
    if (target == null) {
      detail.status = 'failed';
      detail.error = errors.isEmpty ? 'No match found' : errors.join('\n');
      task.failed++;
      return;
    }
    detail.target = target;
    if (task.confirmEach) {
      detail.status = 'matched';
      return;
    }
    await _applyMigration(
      source: detail.source,
      target: target,
      migrateHistory: task.migrateHistory,
      replaceFavorite: task.replaceFavorite,
    );
    detail.status = 'migrated';
    task.migrated++;
  }

  Future<FavoriteItem?> _findMatch(
    FavoriteItem comic,
    String targetSourceKey,
  ) async {
    final source = ComicSource.find(targetSourceKey);
    final searchData = source?.searchPageData;
    if (source == null || searchData == null) {
      throw 'Source unavailable';
    }
    final target = await findMigrationMatchInData(comic, searchData);
    if (target == null) {
      return null;
    }
    final loadComicInfo = source.loadComicInfo;
    if (loadComicInfo == null) {
      throw 'Source unavailable';
    }
    await verifyMigrationTargetReadable(() => loadComicInfo(target.id));
    return target;
  }

  Future<void> _applyMigration({
    required FavoriteItem source,
    required FavoriteItem target,
    required bool migrateHistory,
    required bool replaceFavorite,
  }) async {
    if (migrateHistory) {
      await _copyHistory(source, target);
    }
    final folders = LocalFavoritesManager().find(source.id, source.type);
    for (final folder in folders) {
      await LocalFavoritesManager().addComic(folder, target);
      if (replaceFavorite) {
        await LocalFavoritesManager().deleteComicWithId(
          folder,
          source.id,
          source.type,
        );
      }
    }
  }

  Future<void> _copyHistory(FavoriteItem source, FavoriteItem target) async {
    final history = HistoryManager().find(source.id, source.type);
    if (history == null) {
      return;
    }
    final migrated = buildMigratedHistory(
      source: source,
      target: target,
      history: history,
    );
    await HistoryManager().addHistory(migrated);
  }

  void _completeWaitingTaskIfReady(SourceMigrationTask task) {
    final remaining = task.details.any((detail) => detail.status == 'matched');
    if (remaining) {
      return;
    }
    task.status = SourceMigrationTaskStatus.completed;
    _finish(task);
  }

  void _finish(SourceMigrationTask task) {
    task.finishedAt = DateTime.now();
    currentTasks.remove(task);
    historyTasks.insert(0, task);
    if (historyTasks.length > 50) {
      historyTasks.removeRange(50, historyTasks.length);
    }
    _saveActive();
    _saveHistory();
  }

  SourceMigrationTask? _activeTask(String id) {
    for (final task in currentTasks) {
      if (task.id == id) {
        return task;
      }
    }
    return null;
  }

  void _resumeRunningTasks() {
    for (final task in currentTasks) {
      if (task.status == SourceMigrationTaskStatus.running) {
        unawaited(_run(task));
      }
    }
  }

  void _load() {
    final activeData = appdata.implicitData['source_migration_active_tasks'];
    if (activeData is List) {
      currentTasks
        ..clear()
        ..addAll(
          activeData
              .whereType<Map>()
              .map((item) {
                return SourceMigrationTask.fromJson(
                  Map<String, dynamic>.from(item),
                );
              })
              .where((task) => task.isActive),
        );
    }
    final historyData = appdata.implicitData['source_migration_task_history'];
    if (historyData is List) {
      historyTasks
        ..clear()
        ..addAll(
          historyData.whereType<Map>().map((item) {
            return SourceMigrationTask.fromJson(
              Map<String, dynamic>.from(item),
            );
          }),
        );
    }
  }

  void _saveActive() {
    appdata.implicitData['source_migration_active_tasks'] = currentTasks
        .map((task) => task.toJson())
        .toList();
    appdata.writeImplicitData();
  }

  void _saveHistory() {
    appdata.implicitData['source_migration_task_history'] = historyTasks
        .map((task) => task.toJson())
        .toList();
    appdata.writeImplicitData();
  }

  /// Clear all history tasks
  void clearHistory() {
    historyTasks.clear();
    _saveHistory();
    notifyListeners();
  }

  /// Remove a single history task
  void removeTask(String id) {
    historyTasks.removeWhere((t) => t.id == id);
    _saveHistory();
    notifyListeners();
  }
}

FavoriteItem favoriteItemFromComic(Comic comic) {
  return FavoriteItem(
    id: comic.id,
    name: comic.title,
    coverPath: comic.cover,
    author: comic.subtitle ?? '',
    type: ComicType.fromKey(comic.sourceKey),
    tags: comic.tags ?? const <String>[],
  );
}

/// Search [searchData] for [comic] by title and return the exact-only match,
/// or null when nothing matches. Single search call, mirroring VeneraX.
Future<FavoriteItem?> findMigrationMatchInData(
  FavoriteItem comic,
  SearchPageData searchData,
) async {
  final options =
      searchData.searchOptions?.map((option) => option.defaultValue).toList() ??
      const <String>[];
  final res = searchData.loadPage != null
      ? await searchData.loadPage!(comic.title, 1, options)
      : await searchData.loadNext!(comic.title, null, options);
  final results = res.dataOrNull;
  if (results == null || results.isEmpty) {
    return null;
  }
  final match = matchTitleInResults(comic.title, results);
  if (match == null) {
    return null;
  }
  return favoriteItemFromComic(match);
}

/// Exact-only title match: the first result whose normalized title equals the
/// normalized query, or null. There is deliberately no fallback to the first
/// result (VeneraX `orElse: () => results.first` is removed).
Comic? matchTitleInResults(String queryTitle, List<Comic> results) {
  final normalizedTitle = normalizeMigrationTitle(queryTitle);
  for (final result in results) {
    if (normalizeMigrationTitle(result.title) == normalizedTitle) {
      return result;
    }
  }
  return null;
}

/// Normalize a title for migration matching: Traditional to Simplified,
/// lowercase, then strip whitespace and punctuation/symbols (including CJK
/// brackets). Falls back to the raw title when OpenCC is not initialized.
String normalizeMigrationTitle(String title) {
  var text = title;
  try {
    text = OpenCC.traditionalToSimplified(text);
  } catch (_) {
    // OpenCC not initialized (tests without assets): compare raw text.
  }
  return text.toLowerCase().replaceAll(
    RegExp(r'[\s\p{P}\p{S}]', unicode: true),
    '',
  );
}

/// Reject targets whose details cannot be loaded (for example a banned comic
/// that still shows up in search results). Throws the load error.
Future<void> verifyMigrationTargetReadable(
  Future<Res<ComicDetails>> Function() load,
) async {
  final res = await load();
  if (res.error) {
    throw res.errorMessage ?? 'Target unreadable';
  }
}

/// Pure history-entry mapping for migration: progress coordinates come from
/// [history], identity/display come from [target].
History buildMigratedHistory({
  required FavoriteItem source,
  required FavoriteItem target,
  required History history,
}) {
  final migrated = History.fromMap({
    'type': target.type.value,
    'time': history.time.millisecondsSinceEpoch,
    'title': target.title,
    'subtitle': target.subtitle ?? '',
    'cover': target.cover,
    'ep': history.ep,
    'page': history.page,
    'id': target.id,
    'readEpisode': history.readEpisode.toList(),
    'max_page': history.maxPage,
  });
  migrated.group = history.group;
  return migrated;
}
