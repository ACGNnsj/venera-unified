import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/routing/app_navigation.dart';
import 'package:venera_unified/foundation/app_page_route.dart';
import 'package:venera_unified/foundation/consts.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/edge_back_gesture.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

import 'consts.dart';
import 'layout.dart'
    show wideScreenExpandedSideBarWidth, wideScreenFoldedSideBarWidth;
import 'gesture.dart';

class PaneItemEntry {
  String label;

  IconData icon;

  IconData activeIcon;

  PaneItemEntry({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}

class PaneActionEntry {
  String label;

  IconData icon;

  VoidCallback onTap;

  PaneActionEntry({
    required this.label,
    required this.icon,
    required this.onTap,
  });
}

class NaviPane extends StatefulWidget {
  const NaviPane({
    required this.paneItems,
    required this.paneActions,
    required this.pageBuilder,
    this.initialPage = 0,
    this.onPageChanged,
    required this.observer,
    required this.navigatorKey,
    super.key,
  });

  final List<PaneItemEntry> paneItems;

  final List<PaneActionEntry> paneActions;

  final Widget Function(int page) pageBuilder;

  final void Function(int index)? onPageChanged;

  final int initialPage;

  final NaviObserver observer;

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<NaviPane> createState() => NaviPaneState();

  static NaviPaneState of(BuildContext context) {
    return context.findAncestorStateOfType<NaviPaneState>()!;
  }
}

typedef NaviItemTapListener = void Function(int);

// ①b 画框药丸指示器常量：照抄 miuix VeneraDockedNavBar.kt。
//
// - base 78dp（:84）、拉伸 +26dp（:96）、药丸高 38 / 圆角 19（:126/:129）、
//   阴影 3dp（:127）、描边 0.8dp（:140）、纵向偏移 8dp（:124）、
//   两侧内距 8dp（:80）。
// - 中心位移 spring：dampingRatio 0.76 + StiffnessMediumLow（:111-114）；
//   拉伸两段：先 StiffnessHigh + NoBouncy 撑开（:97），再
//   StiffnessMediumLow + 0.72 回弹（:102）；选中出字 12sp（:197）。
// Compose stiffness 名换算成值：StiffnessHigh = 10000、StiffnessMedium = 1700、
// StiffnessMediumLow = 400；damping 由 [springDamping] 从 ratio 反推。
const dockedPillBaseWidth = 78.0;
const dockedPillStretch = 26.0;
const dockedPillHeight = 38.0;
const dockedPillRadius = 19.0;
const dockedPillTopOffset = 8.0;
const dockedPillSidePadding = 8.0;

/// 从 Compose 的 dampingRatio 反推 Flutter [SpringDescription] 的 damping。
///
/// Compose 与 Flutter 都用 mass = 1 的欠阻尼弹簧：
/// damping = ratio * 2 * sqrt(stiffness)。
double springDamping(double stiffness, double ratio) =>
    ratio * 2 * math.sqrt(stiffness);

/// 药丸中心横向位移的弹簧（miuix :111-114：0.76 + MediumLow）。
SpringDescription get dockedPillCenterSpring => SpringDescription(
  mass: 1,
  stiffness: 400,
  damping: springDamping(400, 0.76),
);

/// 拉伸前半程：高速撑开（miuix :97：High + NoBouncy）。
SpringDescription get dockedPillStretchUpSpring => SpringDescription(
  mass: 1,
  stiffness: 10000,
  damping: springDamping(10000, 1),
);

/// 拉伸后半程：平滑回弹（miuix :102：MediumLow + 0.72）。
SpringDescription get dockedPillStretchDownSpring => SpringDescription(
  mass: 1,
  stiffness: 400,
  damping: springDamping(400, 0.72),
);

/// 选中文字淡入（miuix :190：Medium；Compose spring 默认 ratio 1）。
SpringDescription get dockedPillLabelInSpring => SpringDescription(
  mass: 1,
  stiffness: 1700,
  damping: springDamping(1700, 1),
);

/// 选中文字淡出（miuix :191：High；默认 ratio 1）。
SpringDescription get dockedPillLabelOutSpring => SpringDescription(
  mass: 1,
  stiffness: 10000,
  damping: springDamping(10000, 1),
);

/// 药丸几何：给定栏宽/格数/选中下标/当前拉伸量，算出药丸的左缘与宽度。
///
/// 口径抄 miuix :82-83/:108/:118-119：格宽按扣除两侧内距后均分，
/// 中心落在选中格正中，宽度 = base + 拉伸。下标取 double 以便动画中
/// 逐帧求值（弹簧在线性系统里时长与距离无关，格空间与 dp 空间等价）。
({double left, double width}) dockedPillGeometry({
  required double barWidth,
  required int tabCount,
  required double selectedIndex,
  required double stretch,
}) {
  final cellWidth = (barWidth - dockedPillSidePadding * 2) / tabCount;
  final centerX =
      dockedPillSidePadding + cellWidth * selectedIndex + cellWidth / 2;
  final width = dockedPillBaseWidth + stretch;
  return (left: centerX - width / 2, width: width);
}

class NaviPaneState extends State<NaviPane>
    with SingleTickerProviderStateMixin {
  bool _canPop = true;

  late int _currentPage = widget.initialPage;

  int get currentPage => _currentPage;

  set currentPage(int value) {
    if (value == _currentPage) return;
    _currentPage = value;
    widget.onPageChanged?.call(value);
  }

  void Function()? mainViewUpdateHandler;

  late AnimationController controller;

  final _naviItemTapListeners = <NaviItemTapListener>[];

  void addNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.add(listener);
  }

  void removeNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.remove(listener);
  }

  static const _kBottomBarHeight = 54.0;

  // ②b 侧栏宽唯一口径在 layout.dart；此处直接引用，不留第二份数字。
  static const _kFoldedSideBarWidth = wideScreenFoldedSideBarWidth;

  static const _kSideBarWidth = wideScreenExpandedSideBarWidth;

  static const _kTopBarHeight = 48.0;

  void onNavigatorStateChange() {
    onRebuild(context);
  }

  void updatePage(int index) {
    for (var listener in _naviItemTapListeners) {
      listener(index);
    }
    if (widget.observer.routes.length > 1) {
      widget.navigatorKey.currentState!.popUntil((route) => route.isFirst);
    }
    if (currentPage == index) {
      return;
    }
    setState(() {
      currentPage = index;
    });
    mainViewUpdateHandler?.call();
  }

  @override
  void initState() {
    controller = AnimationController(
      duration: const Duration(milliseconds: 250),
      lowerBound: 0,
      upperBound: 3,
      vsync: this,
    );
    widget.observer.addListener(onNavigatorStateChange);
    super.initState();
  }

  @override
  void didUpdateWidget(covariant NaviPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.observer, widget.observer)) {
      oldWidget.observer.removeListener(onNavigatorStateChange);
      if (oldWidget.navigatorKey == widget.navigatorKey) {
        widget.observer._adoptRoutes(
          oldWidget.observer,
          widget.navigatorKey.currentState,
        );
      }
      widget.observer.addListener(onNavigatorStateChange);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    widget.observer.removeListener(onNavigatorStateChange);
    widget.observer._releaseDetachedNavigator();
    mainViewUpdateHandler = null;
    _naviItemTapListeners.clear();
    super.dispose();
  }

  double targetFormContext(BuildContext context) {
    var width = MediaQuery.of(context).size.width;
    double target = 0;
    if (width > changePoint) {
      target = 2;
    }
    if (width > changePoint2) {
      target = 3;
    }
    return target;
  }

  double? animationTarget;

  void onRebuild(BuildContext context) {
    double target = targetFormContext(context);
    if (controller.value != target || animationTarget != target) {
      if (controller.isAnimating) {
        if (animationTarget == target) {
          return;
        } else {
          controller.stop();
        }
      }
      controller.animateTo(target);
      animationTarget = target;
    }
  }

  @override
  Widget build(BuildContext context) {
    onRebuild(context);
    final mq = MediaQuery.of(context);
    final sideInsets = (App.isMobile && mq.orientation == Orientation.landscape)
        ? EdgeInsets.only(
            left: math.max(mq.viewPadding.left, mq.systemGestureInsets.left),
            right: math.max(mq.viewPadding.right, mq.systemGestureInsets.right),
          )
        : EdgeInsets.zero;
    return _NaviPopScope(
      action: () {
        if (appNavigation.mainNavigatorKey!.currentState!.canPop()) {
          appNavigation.mainNavigatorKey!.currentState!.maybePop();
        } else {
          SystemNavigator.pop();
        }
      },
      popGesture: App.isIOS && context.width >= changePoint,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final value = controller.value;
          Widget content = Stack(
            children: [
              Positioned(
                left: _kFoldedSideBarWidth * ((value - 2.0).clamp(-1.0, 0.0)),
                top: 0,
                bottom: 0,
                child: buildLeft(),
              ),
              Positioned.fill(
                left:
                    _kFoldedSideBarWidth * ((value - 1).clamp(0, 1)) +
                    (_kSideBarWidth - _kFoldedSideBarWidth) *
                        ((value - 2).clamp(0, 1)),
                child: buildMainView(),
              ),
            ],
          );
          if (sideInsets != EdgeInsets.zero) {
            content = Padding(padding: sideInsets, child: content);
          }
          return content;
        },
      ),
    );
  }

  Widget buildMainView() {
    return HeroControllerScope(
      controller: MaterialApp.createMaterialHeroController(),
      child: PopScope(
        canPop: _canPop,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) {
            return;
          }
          widget.navigatorKey.currentState?.maybePop(result);
        },
        child: NotificationListener<NavigationNotification>(
          onNotification: (NavigationNotification notification) {
            final bool nextCanPop = !notification.canHandlePop;
            if (nextCanPop != _canPop) {
              setState(() {
                _canPop = nextCanPop;
              });
            }
            return false;
          },
          child: Navigator(
            observers: [widget.observer],
            key: widget.navigatorKey,
            onGenerateRoute: (settings) => AppPageRoute(
              preventRebuild: false,
              builder: (context) {
                return _NaviMainView(state: this);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget buildMainViewContent() {
    return widget.pageBuilder(currentPage);
  }

  Widget buildTop() {
    return Material(
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 16),
        height: _kTopBarHeight,
        width: double.infinity,
        child: Row(
          children: [
            Text(
              widget.paneItems[currentPage].label,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            for (var action in widget.paneActions)
              Tooltip(
                message: action.label,
                child: IconButton(
                  icon: Icon(action.icon),
                  onPressed: action.onTap,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildBottom() {
    return Material(
      textStyle: Theme.of(context).textTheme.labelSmall,
      elevation: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: _kBottomBarHeight,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Stack(
              children: [
                // ①b 单药丸画在 cell 行之下。
                Positioned.fill(
                  child: _DockedPillIndicator(
                    selectedIndex: currentPage,
                    tabCount: widget.paneItems.length,
                  ),
                ),
                Row(
                  children: List<Widget>.generate(widget.paneItems.length, (
                    index,
                  ) {
                    return Expanded(
                      child: _SingleBottomNaviWidget(
                        enabled: currentPage == index,
                        entry: widget.paneItems[index],
                        onTap: () {
                          updatePage(index);
                        },
                        key: ValueKey(index),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
          // ①a：底部安全区吃在着色面内（miuix VeneraDockedNavBar :211），
          // 而不是栏外。今天与栏外写法像素一致，价值在底栏换独立
          // surface 色那天兑现；横向安全区仍走 :207-212，不动。
          SizedBox(height: context.padding.bottom),
        ],
      ),
    );
  }

  Widget buildLeft() {
    final value = controller.value;
    final topPadding = MediaQuery.paddingOf(context).top;
    final dividerColor = Theme.of(context).colorScheme.outlineVariant;
    const paddingHorizontal = 12.0;
    return Material(
      child: SizedBox(
        width:
            _kFoldedSideBarWidth +
            (_kSideBarWidth - _kFoldedSideBarWidth) * ((value - 2).clamp(0, 1)),
        height: double.infinity,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: paddingHorizontal,
              ),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  SizedBox(height: topPadding),
                  ...List<Widget>.generate(
                    widget.paneItems.length,
                    (index) => _SideNaviWidget(
                      enabled: currentPage == index,
                      entry: widget.paneItems[index],
                      showTitle: value == 3,
                      onTap: () {
                        updatePage(index);
                      },
                      key: ValueKey(index),
                    ),
                  ),
                  const Spacer(),
                  ...List<Widget>.generate(
                    widget.paneActions.length,
                    (index) => _PaneActionWidget(
                      entry: widget.paneActions[index],
                      showTitle: value == 3,
                      key: ValueKey(index + widget.paneItems.length),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
            Positioned(
              top: topPadding,
              right: 0,
              bottom: 0,
              child: ColoredBox(
                color: dividerColor,
                child: const SizedBox(width: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SideNaviWidget extends StatelessWidget {
  const _SideNaviWidget({
    required this.enabled,
    required this.entry,
    required this.onTap,
    required this.showTitle,
    super.key,
  });

  final bool enabled;

  final PaneItemEntry entry;

  final VoidCallback onTap;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = Icon(enabled ? entry.activeIcon : entry.icon);
    return ClickInkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 38,
        decoration: BoxDecoration(
          color: enabled ? colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: showTitle
            ? Row(
                children: [icon, const SizedBox(width: 12), Text(entry.label)],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(4);
  }
}

class _PaneActionWidget extends StatelessWidget {
  const _PaneActionWidget({
    required this.entry,
    required this.showTitle,
    super.key,
  });

  final PaneActionEntry entry;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(entry.icon);
    return ClickInkWell(
      onTap: entry.onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 38,
        child: showTitle
            ? Row(
                children: [icon, const SizedBox(width: 12), Text(entry.label)],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(4);
  }
}

/// ①b 单药丸跨格指示器：一个药丸在整条底栏上平移，切换时前缘拉伸再回弹。
///
/// 画在 cell 行之下（cell 背景透明，药丸从下方透出）。中心动画走「格空间」
/// 下标（double），逐帧由 [dockedPillGeometry] 换算成 dp——旋转/窗口缩放时
/// 几何自动重算，无需 snap 逻辑。动画状态由本 widget 持有，在 Stack 中
/// 位置固定，跨 buildBottom 重建保持。
class _DockedPillIndicator extends StatefulWidget {
  const _DockedPillIndicator({
    required this.selectedIndex,
    required this.tabCount,
  });

  final int selectedIndex;

  final int tabCount;

  @override
  State<_DockedPillIndicator> createState() => _DockedPillIndicatorState();
}

class _DockedPillIndicatorState extends State<_DockedPillIndicator>
    with TickerProviderStateMixin {
  /// 中心位置（格空间下标），初值直接落在选中格，首帧无滑动。
  late final AnimationController _center = AnimationController.unbounded(
    vsync: this,
    value: widget.selectedIndex.toDouble(),
  );

  /// 当前拉伸量（dp），静息为 0。
  late final AnimationController _stretch = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );

  @override
  void dispose() {
    _center.dispose();
    _stretch.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DockedPillIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex == widget.selectedIndex) return;
    // 中心位移 + 拉伸两段，与 miuix LaunchedEffect :90-105 同序。
    // 快速连点时 animateWith 从当前值中断重起，与上游语义一致。
    _center.animateWith(
      SpringSimulation(
        dockedPillCenterSpring,
        _center.value,
        widget.selectedIndex.toDouble(),
        0,
      ),
    );
    _stretch
        .animateWith(
          SpringSimulation(
            dockedPillStretchUpSpring,
            _stretch.value,
            dockedPillStretch,
            0,
          ),
        )
        .then((_) {
          if (!mounted) return;
          _stretch.animateWith(
            SpringSimulation(dockedPillStretchDownSpring, _stretch.value, 0, 0),
          );
        });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tabCount <= 0) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        return AnimatedBuilder(
          animation: Listenable.merge([_center, _stretch]),
          builder: (context, _) {
            final geometry = dockedPillGeometry(
              barWidth: constraints.maxWidth,
              tabCount: widget.tabCount,
              selectedIndex: _center.value,
              stretch: _stretch.value,
            );
            return Stack(
              children: [
                Positioned(
                  left: geometry.left,
                  top: dockedPillTopOffset,
                  width: geometry.width,
                  height: dockedPillHeight,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(dockedPillRadius),
                      color: colors.primaryContainer.withValues(
                        alpha: isDark ? 0.45 : 0.65,
                      ),
                      border: Border.all(
                        width: 0.8,
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.22)
                            : colors.primary.withValues(alpha: 0.25),
                      ),
                      // Compose elevation 3dp 的近似：单层柔阴影。
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.35 : 0.08,
                          ),
                          blurRadius: 3,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _SingleBottomNaviWidget extends StatefulWidget {
  const _SingleBottomNaviWidget({
    required this.enabled,
    required this.entry,
    required this.onTap,
    super.key,
  });

  final bool enabled;

  final PaneItemEntry entry;

  final VoidCallback onTap;

  @override
  State<_SingleBottomNaviWidget> createState() =>
      _SingleBottomNaviWidgetState();
}

class _SingleBottomNaviWidgetState extends State<_SingleBottomNaviWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController controller;

  bool isHovering = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SingleBottomNaviWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      // ①b 选中出字：淡入/淡出走上游弹簧（miuix :190-191）。
      if (widget.enabled) {
        controller.animateWith(
          SpringSimulation(dockedPillLabelInSpring, controller.value, 1, 0),
        );
      } else {
        controller.animateWith(
          SpringSimulation(dockedPillLabelOutSpring, controller.value, 0, 0),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      value: widget.enabled ? 1 : 0,
      vsync: this,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (details) => setState(() => isHovering = true),
          onExit: (details) => setState(() => isHovering = false),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onTap,
            child: buildContent(),
          ),
        );
      },
    );
  }

  Widget buildContent() {
    final value = controller.value;
    // 弹簧动画只渐近 0 永不到 0；低于 epsilon 即视为消失摘除，
    // 否则无形文字常驻树（单测抓到）。
    final labelValue = value < 0.01 ? 0.0 : value;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // miuix :153-158：选中 primary，未选中 onSurface 降 alpha。
    final contentColor = Color.lerp(
      colorScheme.onSurface.withValues(alpha: isDark ? 0.55 : 0.45),
      colorScheme.primary,
      value,
    )!;
    return Center(
      // hover 底只是一块 64×28 背景，内容行不限宽（图标+字常超过 64，
      // 收进同一盒会 RenderFlex 溢出），两者居中叠放。
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 64,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(32)),
              color: isHovering
                  ? colorScheme.surfaceContainer
                  : Colors.transparent,
            ),
          ),
          // ①b：仅选中项出 12sp 字（miuix :188-203），图标 21→22。
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.enabled ? widget.entry.activeIcon : widget.entry.icon,
                size: 21 + value,
                color: contentColor,
              ),
              if (labelValue > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 64),
                      child: Text(
                        widget.entry.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: contentColor.withValues(alpha: labelValue),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class NaviObserver extends NavigatorObserver implements Listenable {
  var routes = Queue<Route>();
  NavigatorState? _owner;

  void _adoptRoutes(NaviObserver previous, NavigatorState? owner) {
    _owner = owner;
    routes
      ..clear()
      ..addAll(previous.routes.where((route) => route.navigator == owner));
    previous._owner = null;
    previous.routes.clear();
  }

  void _releaseDetachedNavigator() {
    if (navigator == null) {
      _owner = null;
      routes.clear();
    }
  }

  void _bindNavigator() {
    if (!identical(_owner, navigator)) {
      _owner = navigator;
      routes.clear();
    }
  }

  int get pageCount {
    int count = 0;
    for (var route in routes) {
      if (route is AppPageRoute) {
        count++;
      }
    }
    return count;
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    _bindNavigator();
    routes.remove(route);
    notifyListeners();
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    _bindNavigator();
    routes.addLast(route);
    notifyListeners();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    _bindNavigator();
    routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    _bindNavigator();
    final stack = routes.toList();
    final index = oldRoute == null ? -1 : stack.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        stack.removeAt(index);
      } else {
        stack[index] = newRoute;
      }
      routes
        ..clear()
        ..addAll(stack);
    } else if (newRoute != null) {
      routes.addLast(newRoute);
    }
    notifyListeners();
  }

  List<VoidCallback> listeners = [];

  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
  }

  void notifyListeners() {
    for (final listener in List<VoidCallback>.of(listeners)) {
      if (listeners.contains(listener)) listener();
    }
  }
}

class _NaviPopScope extends StatefulWidget {
  const _NaviPopScope({
    required this.child,
    this.popGesture = false,
    required this.action,
  });

  final Widget child;
  final bool popGesture;
  final VoidCallback action;

  @override
  State<_NaviPopScope> createState() => _NaviPopScopeState();
}

class _NaviPopScopeState extends State<_NaviPopScope> {
  double _progress = 0;

  @override
  Widget build(BuildContext context) {
    return EdgeBackGestureDetector(
      enabled: () => widget.popGesture,
      onStart: () => _progress = 0,
      onUpdate: (delta) => _progress = (_progress + delta).clamp(0, 1),
      onEnd: (velocity) {
        final shouldPop = velocity.abs() >= 1
            ? velocity > 0 && _progress >= 0.1
            : _progress >= 0.5;
        _progress = 0;
        if (shouldPop) widget.action();
      },
      onCancel: () => _progress = 0,
      child: widget.child,
    );
  }
}

class _NaviMainView extends StatefulWidget {
  const _NaviMainView({required this.state});

  final NaviPaneState state;

  @override
  State<_NaviMainView> createState() => _NaviMainViewState();
}

class _NaviMainViewState extends State<_NaviMainView> {
  NaviPaneState get state => widget.state;

  @override
  void initState() {
    state.mainViewUpdateHandler = _update;
    super.initState();
  }

  void _update() => setState(() {});

  void _detach(NaviPaneState previous) {
    if (previous.mainViewUpdateHandler == _update) {
      previous.mainViewUpdateHandler = null;
    }
  }

  @override
  void didUpdateWidget(covariant _NaviMainView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, state)) {
      _detach(oldWidget.state);
      state.mainViewUpdateHandler = _update;
    }
  }

  @override
  void dispose() {
    _detach(state);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var shouldShowAppBar = state.controller.value < 2;
    return Column(
      children: [
        if (shouldShowAppBar) state.buildTop().paddingTop(context.padding.top),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: shouldShowAppBar,
            child: AnimatedSwitcher(
              duration: fastAnimationDuration,
              child: state.buildMainViewContent(),
            ),
          ),
        ),
        if (shouldShowAppBar) state.buildBottom(),
      ],
    );
  }
}
