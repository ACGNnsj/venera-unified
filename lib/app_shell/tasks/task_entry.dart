import 'dart:async';

import 'package:flutter/foundation.dart';

/// Task families aggregated by the tasks center. Only queues with a central,
/// observable owner are included; dialog-scoped work (comic import/export,
/// backup, storage migration) stays out until it gains a registry.
enum TaskKind { download, pdfImport, followUpdate, dataSync, sourceUpdate }

/// Lifecycle state of one aggregated entry.
enum TaskEntryStatus { running, paused, failed, finished, canceled }

/// One row in the tasks center. Snapshots are cheap and rebuilt on every
/// source notification plus a slow refresh tick; entries never outlive a
/// rebuild, so no disposal is needed.
@immutable
class TaskEntry {
  const TaskEntry({
    required this.id,
    required this.kind,
    required this.title,
    this.detail,
    this.status = TaskEntryStatus.running,
    this.progress,
    this.time,
    this.cancel,
  });

  /// Stable within one rebuild (`<kind>:<queue id>`). Dismiss keys must not
  /// be persisted: ids are only unique per queue.
  final String id;
  final TaskKind kind;
  final String title;
  final String? detail;
  final TaskEntryStatus status;

  /// 0..1, or null for indeterminate work.
  final double? progress;
  final DateTime? time;

  /// Cancels the underlying queue item. Null when the queue exposes no
  /// cancellation (read-only entry).
  final FutureOr<void> Function()? cancel;

  bool get cancellable => cancel != null;
  bool get isRunning => status == TaskEntryStatus.running;
}

/// Newest first; entries without a timestamp sink to the bottom, stable.
List<TaskEntry> sortHistoryEntries(Iterable<TaskEntry> entries) {
  final sorted = entries.toList();
  sorted.sort((a, b) {
    final at = a.time;
    final bt = b.time;
    if (at == null && bt == null) return 0;
    if (at == null) return 1;
    if (bt == null) return -1;
    return bt.compareTo(at);
  });
  return sorted;
}
