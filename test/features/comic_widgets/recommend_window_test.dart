import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_source/models.dart';
import 'package:venera_unified/features/comic_widgets/comic_list.dart';
import 'package:venera_unified/features/comic_widgets/comic_tile.dart';
import 'package:venera_unified/foundation/appdata.dart';

/// Widget-level regression for the Related grid's recommend window
/// ([ComicDetailsPage.buildRecommend]): only the first [_window] comics render
/// at first; building the edge tile grows the window by [_window].
const _window = 6;

Comic _comic(int index) => Comic(
  'Recommend $index',
  '',
  'recommend-$index',
  null,
  const [],
  '',
  'webdav_library',
  null,
  null,
);

Widget _host(List<Comic> comics, {void Function()? onLastItemBuild}) =>
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            SliverGridComics(
              comics: comics,
              onLastItemBuild: onLastItemBuild,
            ),
          ],
        ),
      ),
    );

void main() {
  setUp(() {
    appdata.settings['blockedWords'] = <String>[];
  });

  testWidgets('recommend window shows six first and grows on edge build', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final all = [for (var i = 0; i < 8; i++) _comic(i)];
    var visible = all.take(_window).toList();
    var calls = 0;
    late StateSetter grow;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          grow = setState;
          return _host(
            visible,
            // Mirrors _growRecommendWindow: the edge build only schedules
            // growth for the next frame, never setState during build.
            onLastItemBuild: visible.length < all.length
                ? () {
                    calls++;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      grow(() => visible = all);
                    });
                  }
                : null,
          );
        },
      ),
    );
    expect(find.byType(ComicTile), findsNWidgets(6));
    await tester.pump();
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(ComicTile), findsNWidgets(8));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('recommend window does not grow once all are visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final all = [for (var i = 0; i < 8; i++) _comic(i)];
    await tester.pumpWidget(_host(all));
    await tester.pump();
    expect(find.byType(ComicTile), findsNWidgets(8));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('empty recommend list renders nothing', (tester) async {
    await tester.pumpWidget(_host(const []));
    await tester.pump();
    expect(find.byType(ComicTile), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
