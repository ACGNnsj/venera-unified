import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/history/history_grouping.dart';

void main() {
  final now = DateTime(2026, 10, 27, 12, 30);

  test('按天数切到四个分组', () {
    expect(
      historyBucketOf(DateTime(2026, 10, 27, 1), now: now),
      HistoryBucket.today,
    );
    expect(
      historyBucketOf(DateTime(2026, 10, 26, 23), now: now),
      HistoryBucket.yesterday,
    );
    expect(
      historyBucketOf(DateTime(2026, 10, 21), now: now),
      HistoryBucket.lastWeek,
    );
    expect(
      historyBucketOf(DateTime(2026, 10, 20), now: now),
      HistoryBucket.earlier,
    );
  });

  test('未来时间算今天', () {
    expect(
      historyBucketOf(DateTime(2026, 11, 2), now: now),
      HistoryBucket.today,
    );
  });

  test('分组保持原有顺序并跳过空分组', () {
    final items = [
      (DateTime(2026, 10, 20), 'a'),
      (DateTime(2026, 10, 27), 'b'),
      (DateTime(2026, 10, 25), 'c'),
      (DateTime(2026, 10, 27), 'd'),
    ];
    final grouped = groupByHistoryBucket(items, (item) => item.$1, now: now);
    expect(grouped.keys.toSet(), {
      HistoryBucket.today,
      HistoryBucket.lastWeek,
      HistoryBucket.earlier,
    });
    expect(grouped[HistoryBucket.today]!.map((e) => e.$2), ['b', 'd']);
    expect(grouped[HistoryBucket.lastWeek]!.map((e) => e.$2), ['c']);
    expect(grouped[HistoryBucket.earlier]!.map((e) => e.$2), ['a']);
  });
}
