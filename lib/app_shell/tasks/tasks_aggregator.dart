import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/features/follow_updates/follow_updates_runtime.dart';
import 'package:venera_unified/features/local_comics/import_export/pdf_import_batch.dart';
import 'package:venera_unified/features/local_comics/import_export/pdf_import_tasks.dart';
import 'package:venera_unified/features/local_comics/local.dart';
import 'package:venera_unified/features/sync/data_sync_controller.dart';
import 'package:venera_unified/foundation/translations.dart';

import 'task_entry.dart';

/// One observable queue behind the tasks center. Adapters are read-only:
/// they snapshot queue state and forward cancellation, never mutate queue
/// logic or develop their own task model.
abstract class TaskSource {
  Listenable get listenable;
  List<TaskEntry> currentEntries();
  List<TaskEntry> historyEntries();
}

class DownloadTaskSource implements TaskSource {
  DownloadTaskSource(this.manager);

  final LocalManager manager;

  @override
  Listenable get listenable => manager;

  @override
  List<TaskEntry> currentEntries() => [
    for (final task in manager.downloadingTasks)
      TaskEntry(
        id: 'download:${task.id}',
        kind: TaskKind.download,
        title: task.title,
        detail: task.message.isEmpty ? null : task.message,
        status: task.isError
            ? TaskEntryStatus.failed
            : task.isPaused
            ? TaskEntryStatus.paused
            : TaskEntryStatus.running,
        progress: task.progress.clamp(0.0, 1.0),
        cancel: () => manager.cancelDownload(task),
      ),
  ];

  @override
  List<TaskEntry> historyEntries() => const [];
}

class PdfImportTaskSource implements TaskSource {
  PdfImportTaskSource(this.tasks);

  final PdfImportTasks tasks;

  @override
  Listenable get listenable => tasks;

  @override
  List<TaskEntry> currentEntries() => [
    for (final task in tasks.tasks)
      if (!task.isFinished)
        TaskEntry(
          id: 'pdf_import:${task.name}',
          kind: TaskKind.pdfImport,
          title: task.name,
          detail: _progressText(task.progress, task.fileCount),
          progress: _progressValue(task.progress),
          cancel: () => tasks.cancel(task),
        ),
  ];

  @override
  List<TaskEntry> historyEntries() => [
    for (final task in tasks.tasks)
      if (task.isFinished)
        TaskEntry(
          id: 'pdf_import:${task.name}',
          kind: TaskKind.pdfImport,
          title: task.name,
          detail: _resultText(task.result),
          status: _resultStatus(task.result),
        ),
  ];

  static String? _progressText(
    PdfImportBatchProgress? progress,
    int fileCount,
  ) {
    if (progress == null) return null;
    return '${progress.fileIndex + 1}/$fileCount · ${progress.fileName}';
  }

  static double? _progressValue(PdfImportBatchProgress? progress) {
    if (progress == null || progress.fileCount <= 0) return null;
    return (progress.fileIndex / progress.fileCount).clamp(0.0, 1.0);
  }

  static String _resultText(PdfImportBatchResult? result) {
    if (result == null) return '';
    final imported = result.count(PdfImportStatus.imported);
    final skipped = result.count(PdfImportStatus.skipped);
    final failed =
        result.count(PdfImportStatus.failed) +
        result.count(PdfImportStatus.cancelled);
    return '@imported imported · @skipped skipped · @failed failed'.tlParams({
      'imported': imported,
      'skipped': skipped,
      'failed': failed,
    });
  }

  static TaskEntryStatus _resultStatus(PdfImportBatchResult? result) {
    if (result == null) return TaskEntryStatus.finished;
    if (result.items.isNotEmpty &&
        result.items.every(
          (item) => item.status == PdfImportStatus.cancelled,
        )) {
      return TaskEntryStatus.canceled;
    }
    if (result.count(PdfImportStatus.failed) > 0) {
      return TaskEntryStatus.failed;
    }
    return TaskEntryStatus.finished;
  }
}

class FollowUpdateTaskSource implements TaskSource {
  FollowUpdateTaskSource(this.runtime);

  final FollowUpdatesRuntime runtime;

  @override
  Listenable get listenable => runtime.changes;

  @override
  List<TaskEntry> currentEntries() => [
    if (runtime.isRunning)
      TaskEntry(
        id: 'follow_update:check',
        kind: TaskKind.followUpdate,
        title: 'Follow Update'.tl,
        cancel: () => runtime.cancelChecking(),
      ),
  ];

  @override
  List<TaskEntry> historyEntries() => const [];
}

class DataSyncTaskSource implements TaskSource {
  DataSyncTaskSource(this.controller);

  final DataSyncController controller;

  @override
  Listenable get listenable => controller;

  @override
  List<TaskEntry> currentEntries() => [
    if (controller.isUploading || controller.isDownloading)
      TaskEntry(
        id: 'data_sync:transfer',
        kind: TaskKind.dataSync,
        title: 'Sync Data'.tl,
        detail: controller.isUploading ? 'Upload'.tl : 'Download'.tl,
      ),
  ];

  @override
  List<TaskEntry> historyEntries() => const [];
}

class SourceUpdateTaskSource implements TaskSource {
  SourceUpdateTaskSource(this.service, {required this.nameOf});

  final SourceUpdateService service;

  /// Resolves a source key to a display name; falls back to the key.
  final String Function(String key) nameOf;

  @override
  Listenable get listenable => service;

  @override
  List<TaskEntry> currentEntries() => [
    if (service.isChecking)
      TaskEntry(
        id: 'source_update:checking',
        kind: TaskKind.sourceUpdate,
        title: 'Update Sources'.tl,
        detail: 'Checking'.tl,
      ),
    for (final key in service.updatingKeys)
      TaskEntry(
        id: 'source_update:$key',
        kind: TaskKind.sourceUpdate,
        title: nameOf(key),
        cancel: () => service.cancel(key),
      ),
  ];

  @override
  List<TaskEntry> historyEntries() => const [];
}

/// Fans queue snapshots into one notifier for the tasks page.
///
/// Sources notify unevenly (some transitions publish nothing observable), so
/// beyond forwarding source notifications the aggregator re-publishes on a
/// slow tick while it has listeners. Snapshots are cheap getter reads; the
/// tick only exists to close observability gaps, never to drive queue logic.
class TasksAggregator with ChangeNotifier {
  TasksAggregator({
    required this.sources,
    this.refreshInterval = const Duration(seconds: 1),
    this.enableTicker = true,
  }) {
    for (final source in sources) {
      source.listenable.addListener(_forward);
    }
  }

  final List<TaskSource> sources;
  final Duration refreshInterval;
  final bool enableTicker;
  Timer? _ticker;
  int _listenerCount = 0;
  bool _disposed = false;

  List<TaskEntry> get current => [
    for (final source in sources) ...source.currentEntries(),
  ];

  List<TaskEntry> get history => sortHistoryEntries([
    for (final source in sources) ...source.historyEntries(),
  ]);

  void _forward() {
    if (!_disposed) notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listenerCount++;
    _ticker ??= enableTicker
        ? Timer.periodic(refreshInterval, (_) => _forward())
        : null;
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listenerCount--;
    if (_listenerCount <= 0) {
      _listenerCount = 0;
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    for (final source in sources) {
      source.listenable.removeListener(_forward);
    }
    super.dispose();
  }
}
