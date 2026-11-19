import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_details/chapter_order.dart';

void main() {
  test('naturalCompare orders digit runs numerically', () {
    expect(naturalCompare('page2', 'page10'), lessThan(0));
    expect(naturalCompare('page10', 'page2'), greaterThan(0));
    expect(naturalCompare('Chapter 1', 'chapter 1'), 0);
  });

  test('apply keeps source and mirrors reverse', () {
    const titles = ['b', 'a', 'c'];
    expect(ChapterOrder.source.apply([0, 1, 2], titles), [0, 1, 2]);
    expect(ChapterOrder.reverse.apply([0, 1, 2], titles), [2, 1, 0]);
  });

  test('apply sorts by title with index tie-break', () {
    const titles = ['Ch 10', 'Ch 2', 'Ch 2'];
    expect(ChapterOrder.titleAscending.apply([0, 1, 2], titles), [1, 2, 0]);
    expect(ChapterOrder.titleDescending.apply([0, 1, 2], titles), [0, 1, 2]);
  });

  test('resolve honors the legacy reverse flag', () {
    expect(
      ChapterOrder.resolve(null, legacyReverse: true),
      ChapterOrder.reverse,
    );
    expect(
      ChapterOrder.resolve('source', legacyReverse: false),
      ChapterOrder.source,
    );
    expect(
      ChapterOrder.resolve('titleAscending', legacyReverse: false),
      ChapterOrder.titleAscending,
    );
  });

  test('display drops same-id same-title repeats', () {
    const ids = ['a', 'a', 'a', 'b'];
    const titles = ['Ch 1', 'ch  1 ', 'Ch 2', 'Ch 1'];
    expect(
      ChapterVisibility.display(
        order: ChapterOrder.source,
        ids: ids,
        titles: titles,
        hideDuplicates: true,
      ),
      [0, 2, 3],
    );
    expect(
      ChapterVisibility.display(
        order: ChapterOrder.reverse,
        ids: ids,
        titles: titles,
        hideDuplicates: true,
      ),
      [3, 2, 0],
    );
    expect(
      ChapterVisibility.display(
        order: ChapterOrder.source,
        ids: ids,
        titles: titles,
        hideDuplicates: false,
      ),
      [0, 1, 2, 3],
    );
  });
}
