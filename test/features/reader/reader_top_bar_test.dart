import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/reader/top_bar.dart';

Widget _harness(double width, Widget child) {
  return MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(width: width, height: 120, child: child),
        ),
      ),
    ),
  );
}

Widget _topBar() => ReaderTopBar(
  title: '标题',
  chapterTitle: '第一章',
  actions: const [Icon(Icons.more_horiz)],
  onBack: () {},
);

void main() {
  testWidgets('宽屏上顶栏内容居中且不超过 540 宽', (tester) async {
    await tester.pumpWidget(_harness(1200, _topBar()));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byType(Row));
    expect(size.width, readerTopBarMaxWidth);

    final barCenter = tester.getCenter(find.byType(ReaderTopBar));
    final rowCenter = tester.getCenter(find.byType(Row));
    expect((rowCenter.dx - barCenter.dx).abs(), lessThan(0.5));
  });

  testWidgets('窄屏上顶栏仍铺满可用宽度', (tester) async {
    await tester.pumpWidget(_harness(360, _topBar()));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(Row)).width, 360);
  });
}
