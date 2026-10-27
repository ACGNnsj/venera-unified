import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/features/history/history_model.dart';
import 'package:venera_unified/features/local_comics/local_comic_model.dart';
import 'package:venera_unified/features/random/random_comic_picker.dart';
import 'package:venera_unified/foundation/comic_type.dart';

class _FakeSource implements RandomComicDataSource {
  _FakeSource(this.items);

  final List<Comic> items;
  int rowsRead = 0;
  int calls = 0;

  @override
  int count() => items.length;

  @override
  List<Comic> readRange(int offset, int limit) {
    calls++;
    final start = offset.clamp(0, items.length);
    final end = min(start + limit, items.length);
    final rows = items.sublist(start, end);
    rowsRead += rows.length;
    return rows;
  }
}

Comic _comic(String id) =>
    Comic('t$id', 'c$id', id, null, null, '', 'test', null, null);

History _history(
  String id, {
  int page = 1,
  int? maxPage,
  Set<String> readEpisode = const {},
}) => History(
  type: ComicType.fromKey('test'),
  time: DateTime(2026, 10, 27),
  title: 't$id',
  subtitle: '',
  cover: 'c$id',
  ep: 1,
  page: page,
  id: id,
  readEpisode: Set.of(readEpisode),
  maxPage: maxPage,
  readDurationMs: 0,
);

LocalComic _local(String id, {Map<String, String>? chapters}) => LocalComic(
  id: id,
  title: 't$id',
  subtitle: '',
  tags: const [],
  directory: id,
  chapters: chapters == null ? null : ComicChapters(chapters),
  cover: 'c$id',
  comicType: ComicType.local,
  downloadedChapters: const [],
  createdAt: DateTime(2026, 10, 27),
);

void main() {
  test('空库返回 null 且只读 count', () {
    final source = _FakeSource([]);
    expect(RandomComicPicker.pick(source), isNull);
    expect(source.calls, 0);
  });

  test('小库精确均匀：每个候选都可能被抽中', () {
    final source = _FakeSource([_comic('a'), _comic('b'), _comic('c')]);
    final seen = <String>{};
    for (var seed = 0; seed < 50; seed++) {
      final picked = RandomComicPicker.pick(
        source,
        random: Random(seed),
      );
      seen.add(picked!.id);
    }
    expect(seen, {'a', 'b', 'c'});
  });

  test('大库有界读取：万级库读取条数不超过预算', () {
    final items = [for (var i = 0; i < 10000; i++) _comic('c$i')];
    final source = _FakeSource(items);
    final picked = RandomComicPicker.pick(
      source,
      random: Random(42),
      maxReads: 200,
      windowSize: 25,
    );
    expect(picked, isNotNull);
    expect(source.rowsRead, lessThanOrEqualTo(200));
    expect(source.rowsRead, greaterThan(0));
  });

  test('大库过滤态同样有界', () {
    final items = [for (var i = 0; i < 10000; i++) _comic('c$i')];
    // 只有尾部 10 本未读，命中稀疏。
    final progress = {for (var i = 0; i < 9990; i++) 'c$i': _history('c$i')};
    final source = _FakeSource(items);
    RandomComicPicker.pick(
      source,
      status: RandomComicStatus.notStarted,
      historyOf: (id, _) => progress[id],
      random: Random(7),
      maxReads: 200,
      windowSize: 25,
    );
    expect(source.rowsRead, lessThanOrEqualTo(200));
  });

  test('未读只抽无历史的', () {
    final source = _FakeSource([_comic('read'), _comic('fresh')]);
    final progress = {'read': _history('read')};
    for (var seed = 0; seed < 20; seed++) {
      final picked = RandomComicPicker.pick(
        source,
        status: RandomComicStatus.notStarted,
        historyOf: (id, _) => progress[id],
        random: Random(seed),
      );
      expect(picked!.id, 'fresh');
    }
  });

  test('在读/完结按页码划分', () {
    final source = _FakeSource([_comic('half'), _comic('done')]);
    History? lookup(String id, ComicType _) => switch (id) {
      'half' => _history('half', page: 3, maxPage: 10),
      'done' => _history('done', page: 10, maxPage: 10),
      _ => null,
    };
    final reading = RandomComicPicker.pick(
      source,
      status: RandomComicStatus.inProgress,
      historyOf: lookup,
      random: Random(1),
    );
    expect(reading!.id, 'half');
    final completed = RandomComicPicker.pick(
      source,
      status: RandomComicStatus.completed,
      historyOf: lookup,
      random: Random(1),
    );
    expect(completed!.id, 'done');
  });

  test('无 maxPage 时不判完结', () {
    final source = _FakeSource([_comic('a')]);
    final completed = RandomComicPicker.pick(
      source,
      status: RandomComicStatus.completed,
      historyOf: (id, _) => _history(id, page: 99),
      random: Random(1),
    );
    expect(completed, isNull);
  });

  test('本地漫画按已读章节数判完结', () {
    final chapters = {'1': 'ch1', '2': 'ch2'};
    final source = _FakeSource([
      _local('half', chapters: chapters),
      _local('done', chapters: chapters),
    ]);
    History? lookup(String id, ComicType _) => switch (id) {
      'half' => _history('half', readEpisode: {'1'}),
      'done' => _history('done', readEpisode: {'1', '2'}),
      _ => null,
    };
    final completed = RandomComicPicker.pick(
      source,
      status: RandomComicStatus.completed,
      historyOf: lookup,
      random: Random(1),
    );
    expect(completed!.id, 'done');
  });

  test('History 候选直接用自身进度，不查库', () {
    final source = _FakeSource([
      _history('half', page: 2, maxPage: 9),
      _history('done', page: 9, maxPage: 9),
    ]);
    var lookups = 0;
    final completed = RandomComicPicker.pick(
      source,
      status: RandomComicStatus.completed,
      historyOf: (id, type) {
        lookups++;
        return null;
      },
      random: Random(1),
    );
    expect(completed!.id, 'done');
    expect(lookups, 0);
  });

  test('无匹配时返回 null', () {
    final source = _FakeSource([_comic('a')]);
    final picked = RandomComicPicker.pick(
      source,
      status: RandomComicStatus.notStarted,
      historyOf: (id, _) => _history(id),
      random: Random(1),
    );
    expect(picked, isNull);
  });

  test('种子 Random 结果可复现', () {
    final source = _FakeSource([for (var i = 0; i < 100; i++) _comic('c$i')]);
    final first = RandomComicPicker.pick(source, random: Random(1234));
    final second = RandomComicPicker.pick(source, random: Random(1234));
    expect(first!.id, second!.id);
  });
}
