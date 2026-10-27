/// 历史页的时间分组。
enum HistoryBucket { today, yesterday, lastWeek, earlier }

/// 把阅读时间落到一个分组。
///
/// [now] 显式传入而不是读时钟，方便单测；设备时钟被回拨时未来时间算「今天」。
HistoryBucket historyBucketOf(DateTime time, {required DateTime now}) {
  final day = DateTime(time.year, time.month, time.day);
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(day).inDays;
  if (days <= 0) return HistoryBucket.today;
  if (days == 1) return HistoryBucket.yesterday;
  if (days < 7) return HistoryBucket.lastWeek;
  return HistoryBucket.earlier;
}

/// 按分组切分并保持传入顺序；空分组不会出现。
Map<HistoryBucket, List<T>> groupByHistoryBucket<T>(
  Iterable<T> items,
  DateTime Function(T) timeOf, {
  required DateTime now,
}) {
  final grouped = <HistoryBucket, List<T>>{};
  for (final item in items) {
    (grouped[historyBucketOf(timeOf(item), now: now)] ??= []).add(item);
  }
  return grouped;
}
