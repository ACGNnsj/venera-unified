import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/app_shell/tasks/task_entry.dart';
import 'package:venera_unified/app_shell/tasks/tasks_aggregator.dart';

class _FakeSource extends ChangeNotifier implements TaskSource {
  List<TaskEntry> current = [];
  List<TaskEntry> history = [];

  @override
  Listenable get listenable => this;

  @override
  List<TaskEntry> currentEntries() => current;

  @override
  List<TaskEntry> historyEntries() => history;

  void publish() => notifyListeners();
}

TaskEntry _entry(
  String id, {
  TaskKind kind = TaskKind.download,
  TaskEntryStatus status = TaskEntryStatus.running,
  DateTime? time,
  bool cancellable = false,
  void Function()? onCancel,
}) => TaskEntry(
  id: id,
  kind: kind,
  title: id,
  status: status,
  time: time,
  cancel: cancellable ? (() => onCancel?.call()) : null,
);

void main() {
  group('sortHistoryEntries', () {
    test('orders newest first with unknown times last', () {
      final entries = [
        _entry('no-time'),
        _entry('old', time: DateTime(2024)),
        _entry('new', time: DateTime(2026)),
        _entry('mid', time: DateTime(2025)),
      ];

      final sorted = sortHistoryEntries(entries);

      expect(sorted.map((e) => e.id), ['new', 'mid', 'old', 'no-time']);
    });
  });

  group('TasksAggregator', () {
    test('merges current entries across sources in order', () {
      final first = _FakeSource()..current = [_entry('a'), _entry('b')];
      final second = _FakeSource()..current = [_entry('c')];
      final aggregator = TasksAggregator(
        sources: [first, second],
        enableTicker: false,
      );
      addTearDown(aggregator.dispose);

      expect(aggregator.current.map((e) => e.id), ['a', 'b', 'c']);
    });

    test('sorts merged history newest first', () {
      final first = _FakeSource()
        ..history = [_entry('old', time: DateTime(2024)), _entry('no-time')];
      final second = _FakeSource()
        ..history = [_entry('new', time: DateTime(2026))];
      final aggregator = TasksAggregator(
        sources: [first, second],
        enableTicker: false,
      );
      addTearDown(aggregator.dispose);

      expect(aggregator.history.map((e) => e.id), ['new', 'old', 'no-time']);
    });

    test('forwards source notifications', () {
      final source = _FakeSource();
      final aggregator = TasksAggregator(
        sources: [source],
        enableTicker: false,
      );
      addTearDown(aggregator.dispose);
      var notified = 0;
      aggregator.addListener(() => notified++);

      source.current = [_entry('a')];
      source.publish();

      expect(notified, 1);
      expect(aggregator.current.map((e) => e.id), ['a']);
    });

    test('entry cancel reaches the owning queue', () {
      var cancelled = 0;
      final source = _FakeSource()
        ..current = [
          _entry('a', cancellable: true, onCancel: () => cancelled++),
          _entry('b'),
        ];
      final aggregator = TasksAggregator(
        sources: [source],
        enableTicker: false,
      );
      addTearDown(aggregator.dispose);

      final entries = aggregator.current;
      expect(entries[0].cancellable, isTrue);
      expect(entries[1].cancellable, isFalse);
      entries[0].cancel!();
      expect(cancelled, 1);
    });

    test('dispose detaches from sources', () {
      final source = _FakeSource();
      final aggregator = TasksAggregator(
        sources: [source],
        enableTicker: false,
      );
      var notified = 0;
      aggregator.addListener(() => notified++);
      aggregator.dispose();

      source.publish();

      expect(notified, 0);
    });
  });
}
