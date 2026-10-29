import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/components/layout.dart';
import 'package:venera_unified/components/navigation_bar.dart';
import 'package:venera_unified/features/reader/progress_bar.dart';

void main() {
  group('①b 药丸几何', () {
    test('静息态中心落在选中格正中', () {
      // 栏宽 400，4 格：格宽 (400-16)/4 = 96；0 格中心 x = 8+48 = 56。
      final g0 = dockedPillGeometry(
        barWidth: 400,
        tabCount: 4,
        selectedIndex: 0,
        stretch: 0,
      );
      expect(g0.width, 78);
      expect(g0.left, 56 - 39);
      // 1 格中心 x = 8+96+48 = 152。
      final g1 = dockedPillGeometry(
        barWidth: 400,
        tabCount: 4,
        selectedIndex: 1,
        stretch: 0,
      );
      expect(g1.left, 152 - 39);
    });

    test('拉伸只加宽不偏心 + 小数下标逐帧可求值', () {
      final g = dockedPillGeometry(
        barWidth: 400,
        tabCount: 4,
        selectedIndex: 1,
        stretch: 26,
      );
      expect(g.width, 104);
      expect(g.left + g.width / 2, 152);
      final mid = dockedPillGeometry(
        barWidth: 400,
        tabCount: 4,
        selectedIndex: 0.5,
        stretch: 0,
      );
      expect(mid.left + mid.width / 2, 104);
    });
  });

  group('①b 弹簧口径', () {
    test('damping = ratio * 2 * sqrt(stiffness)', () {
      expect(springDamping(10000, 1), 200);
      expect(springDamping(400, 0.72), closeTo(28.8, 1e-9));
      expect(springDamping(400, 0.76), closeTo(30.4, 1e-9));
      expect(springDamping(1700, 1), closeTo(82.46211251235322, 1e-9));
    });

    test('四组弹簧 stiffness/damping 与上游一致', () {
      final center = dockedPillCenterSpring;
      expect(center.stiffness, 400);
      expect(center.damping, closeTo(30.4, 1e-9));
      expect(dockedPillStretchUpSpring.stiffness, 10000);
      expect(dockedPillStretchUpSpring.damping, 200);
      expect(dockedPillStretchDownSpring.damping, closeTo(28.8, 1e-9));
      expect(dockedPillLabelInSpring.stiffness, 1700);
      expect(dockedPillLabelOutSpring.stiffness, 10000);
    });

    test('药丸常量抄上游', () {
      expect(dockedPillBaseWidth, 78);
      expect(dockedPillStretch, 26);
      expect(dockedPillHeight, 38);
      expect(dockedPillRadius, 19);
      expect(dockedPillTopOffset, 8);
      expect(dockedPillSidePadding, 8);
    });
  });

  group('②b 图片墙列数反推', () {
    test('手机档返回 null（保持容器实测，Q2A）', () {
      expect(imageWallColumnCount(null), isNull);
      expect(imageWallColumnCount(400), isNull);
      // 恰好 600 归手机档（比较符 `>`，与 master nav:251 一致）。
      expect(imageWallColumnCount(600), isNull);
    });

    test('Medium 档扣 72，下限 3', () {
      // (601-72)/200 = 2.645 → 3。
      expect(imageWallColumnCount(601), 3);
      // (800-72)/200 = 3.64 → 4。
      expect(imageWallColumnCount(800), 4);
      // 恰好 1300 仍是 Medium（`>` 语义）：(1300-72)/200 = 6.14 → 7。
      expect(imageWallColumnCount(1300), 7);
    });

    test('Expanded 档扣 224', () {
      // (1301-224)/200 = 5.385 → 6。
      expect(imageWallColumnCount(1301), 6);
      // (1920-224)/200 = 8.48 → 9。
      expect(imageWallColumnCount(1920), 9);
    });

    test('侧栏宽唯一口径 + 内容列 840', () {
      expect(wideScreenFoldedSideBarWidth, 72);
      expect(wideScreenExpandedSideBarWidth, 224);
      expect(contentColumnMaxWidth, 840);
    });
  });

  group('①a 底栏结构', () {
    testWidgets('着色面 54 + 安全区吃在面内', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(padding: EdgeInsets.only(bottom: 34)),
            child: NaviPane(
              paneItems: [
                PaneItemEntry(
                  label: 'Home',
                  icon: Icons.home,
                  activeIcon: Icons.home,
                ),
              ],
              paneActions: const [],
              pageBuilder: (_) => const Text('content'),
              observer: NaviObserver(),
              navigatorKey: GlobalKey<NavigatorState>(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 着色面高 54。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.constraints?.minHeight == 54 &&
              w.constraints?.maxHeight == 54,
        ),
        findsOneWidget,
      );
      // 安全区盒子在 buildBottom 的 Column 内（高 34、非 cell 间距）。
      expect(
        find.byWidgetPredicate(
          (w) => w is SizedBox && w.height == 34 && w.width == null,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('①b 仅选中项出字', () {
    testWidgets('切换选中项后文字跟着走', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: NaviPane(
            paneItems: [
              PaneItemEntry(
                label: 'Home',
                icon: Icons.home,
                activeIcon: Icons.home,
              ),
              PaneItemEntry(
                label: 'Search',
                icon: Icons.search,
                activeIcon: Icons.search,
              ),
            ],
            paneActions: const [],
            pageBuilder: (_) => const Text('content'),
            observer: NaviObserver(),
            navigatorKey: GlobalKey<NavigatorState>(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 顶栏也会显示当前页标题，限定在底栏着色面内找。
      final bottomBar = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.constraints?.minHeight == 54 &&
            w.constraints?.maxHeight == 54,
      );
      expect(bottomBar, findsOneWidget);
      Finder barText(String label) =>
          find.descendant(of: bottomBar, matching: find.text(label));
      expect(barText('Home'), findsOneWidget);
      expect(barText('Search'), findsNothing);
      await tester.tap(
        find.descendant(of: bottomBar, matching: find.byIcon(Icons.search)),
      );
      await tester.pumpAndSettle();
      expect(barText('Search'), findsOneWidget);
      expect(barText('Home'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('②b 控制岛 540', () {
    Future<void> pumpBar(WidgetTester tester, Size surface) async {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderBottomBar(
              label: 'E1 : P1',
              actions: const [
                IconButton(onPressed: null, icon: Icon(Icons.add)),
              ],
              page: 1,
              maxPage: 10,
              reversed: false,
              isOpen: true,
              onPageChanged: (_) {},
              onPrevious: () {},
              onNext: () {},
              previousTooltip: 'prev',
              nextTooltip: 'next',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('宽窗居中收口到 540', (tester) async {
      await pumpBar(tester, const Size(1000, 800));
      final bar = find.byWidgetPredicate(
        (w) => w is SizedBox && w.height == 105 && w.width == null,
      );
      expect(bar, findsOneWidget);
      expect(tester.getSize(bar), const Size(540, 105));
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机档约束不生效（400 原样通过）', (tester) async {
      await pumpBar(tester, const Size(400, 800));
      final bar = find.byWidgetPredicate(
        (w) => w is SizedBox && w.height == 105 && w.width == null,
      );
      expect(bar, findsOneWidget);
      expect(tester.getSize(bar), const Size(400, 105));
      expect(tester.takeException(), isNull);
    });
  });
}
