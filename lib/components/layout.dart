import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:venera_unified/foundation/consts.dart';
import 'package:venera_unified/foundation/global_preference_store.dart';

/// 侧栏宽唯一口径：Medium 档折叠 72 / Expanded 档展开 224。
///
/// navigation_bar 的渲染与图片墙列数反推都从这里取值。上游曾两处各写
/// 一次导致 72/224 vs 80/200 漂移（research/06-miuix-design.md），此处
/// 只许有一处。
const wideScreenFoldedSideBarWidth = 72.0;
const wideScreenExpandedSideBarWidth = 224.0;

/// 阅读型内容列最大宽度（②b 先接设置页右栏，其余页逐页接）。
const contentColumnMaxWidth = 840.0;

/// 图片墙列数反推（Q2A：仅 window > 600 的宽窗档生效）。
///
/// 口径抄上游 `imageWallColumnCount`（WideScreenPolicy.kt:193-201）：
/// avail = 窗宽 − 本档侧栏宽，每列预算 200dp 向上取整，侧栏档下限 3。
/// 与上游唯一偏差：手机档返回 null，调用方保持容器实测不变（lead 裁决，
/// 不执行上游的"手机恒 2"）。
int? imageWallColumnCount(double? windowWidth) {
  if (windowWidth == null || windowWidth <= changePoint) return null;
  final sidebar = windowWidth > changePoint2
      ? wideScreenExpandedSideBarWidth
      : wideScreenFoldedSideBarWidth;
  final avail = math.max(0.0, windowWidth - sidebar);
  return math.max(3, (avail / 200.0).ceil());
}

class SliverGridViewWithFixedItemHeight extends StatelessWidget {
  const SliverGridViewWithFixedItemHeight({
    required this.delegate,
    required this.maxCrossAxisExtent,
    required this.itemHeight,
    super.key,
  });

  final SliverChildDelegate delegate;

  final double maxCrossAxisExtent;

  final double itemHeight;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) => SliverGrid(
        delegate: delegate,
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxCrossAxisExtent,
          childAspectRatio: calcChildAspectRatio(constraints.crossAxisExtent),
        ),
      ),
    );
  }

  double calcChildAspectRatio(double width) {
    var crossItems = width ~/ maxCrossAxisExtent;
    if (width % maxCrossAxisExtent != 0) {
      crossItems += 1;
    }
    final itemWidth = width / crossItems;
    return itemWidth / itemHeight;
  }
}

class SliverGridDelegateWithFixedHeight extends SliverGridDelegate {
  const SliverGridDelegateWithFixedHeight({
    required this.maxCrossAxisExtent,
    required this.itemHeight,
  });

  final double maxCrossAxisExtent;

  final double itemHeight;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final width = constraints.crossAxisExtent;
    var crossItems = width ~/ maxCrossAxisExtent;
    if (width % maxCrossAxisExtent != 0) {
      crossItems += 1;
    }
    return SliverGridRegularTileLayout(
      crossAxisCount: crossItems,
      mainAxisStride: itemHeight,
      crossAxisStride: width / crossItems,
      childMainAxisExtent: itemHeight,
      childCrossAxisExtent: width / crossItems,
      reverseCrossAxis: false,
    );
  }

  @override
  bool shouldRelayout(covariant SliverGridDelegate oldDelegate) {
    if (oldDelegate is! SliverGridDelegateWithFixedHeight) return true;
    if (oldDelegate.maxCrossAxisExtent != maxCrossAxisExtent ||
        oldDelegate.itemHeight != itemHeight) {
      return true;
    }
    return false;
  }
}

class SliverGridDelegateWithComics extends SliverGridDelegate {
  SliverGridDelegateWithComics({
    this.galleryColumns,
    this.forceDetailed = false,
    this.windowWidth,
  });

  final int? galleryColumns;

  final bool forceDetailed;

  /// 窗口宽（>600 才参与图片墙列数反推；null/手机档保持容器实测）。
  final double? windowWidth;

  final bool useBriefMode =
      GlobalPreferenceStore(
        appdata.settings,
      ).read(DiscoveryPreferences.comicDisplayMode) ==
      'brief';

  final double scale = GlobalPreferenceStore(
    appdata.settings,
  ).read(DiscoveryPreferences.comicTileScale).toDouble();

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final wideColumns = imageWallColumnCount(windowWidth);
    if (galleryColumns != null) {
      // 用户定死了列数就尊重配置，只在自动档（<=0）反推。
      var count = galleryColumns!;
      if (count <= 0 && wideColumns != null) {
        count = wideColumns;
      }
      return getGalleryModeLayout(constraints, count);
    } else if (useBriefMode && !forceDetailed) {
      return getBriefModeLayout(constraints, scale, wideColumns);
    } else {
      // 详细模式是行式布局而非图片墙，保持容器实测。
      return getDetailedModeLayout(constraints, scale);
    }
  }

  SliverGridLayout getGalleryModeLayout(
    SliverConstraints constraints,
    int configuredColumns,
  ) {
    const maxItemWidth = 144.0;
    const childAspectRatio = 0.64;
    final width = constraints.crossAxisExtent;
    var crossAxisCount = configuredColumns;
    if (crossAxisCount <= 0) {
      crossAxisCount = math.max(1, (width / maxItemWidth).ceil());
    }
    final childCrossAxisExtent = width / crossAxisCount;
    final childMainAxisExtent = childCrossAxisExtent / childAspectRatio;
    return SliverGridRegularTileLayout(
      crossAxisCount: crossAxisCount,
      mainAxisStride: childMainAxisExtent,
      crossAxisStride: childCrossAxisExtent,
      childMainAxisExtent: childMainAxisExtent,
      childCrossAxisExtent: childCrossAxisExtent,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  SliverGridLayout getDetailedModeLayout(
    SliverConstraints constraints,
    double scale,
  ) {
    const minCrossAxisExtent = 360;
    final itemHeight = 152 * scale;
    final width = constraints.crossAxisExtent;
    var crossItems = width ~/ minCrossAxisExtent;
    crossItems = math.max(1, crossItems);
    return SliverGridRegularTileLayout(
      crossAxisCount: crossItems,
      mainAxisStride: itemHeight,
      crossAxisStride: width / crossItems,
      childMainAxisExtent: itemHeight,
      childCrossAxisExtent: width / crossItems,
      reverseCrossAxis: false,
    );
  }

  SliverGridLayout getBriefModeLayout(
    SliverConstraints constraints,
    double scale, [
    int? columnCountOverride,
  ]) {
    final maxCrossAxisExtent = 192.0 * scale;
    const childAspectRatio = 0.64;
    const crossAxisSpacing = 0.0;
    int crossAxisCount =
        columnCountOverride ??
        (constraints.crossAxisExtent / (maxCrossAxisExtent + crossAxisSpacing))
            .ceil();
    // Ensure a minimum count of 1, can be zero and result in an infinite extent
    // below when the window size is 0.
    crossAxisCount = math.max(1, crossAxisCount);
    final double usableCrossAxisExtent = math.max(
      0.0,
      constraints.crossAxisExtent - crossAxisSpacing * (crossAxisCount - 1),
    );
    final double childCrossAxisExtent = usableCrossAxisExtent / crossAxisCount;
    final double childMainAxisExtent = childCrossAxisExtent / childAspectRatio;
    return SliverGridRegularTileLayout(
      crossAxisCount: crossAxisCount,
      mainAxisStride: childMainAxisExtent,
      crossAxisStride: childCrossAxisExtent + crossAxisSpacing,
      childMainAxisExtent: childMainAxisExtent,
      childCrossAxisExtent: childCrossAxisExtent,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(covariant SliverGridDelegate oldDelegate) {
    if (oldDelegate is! SliverGridDelegateWithComics) return true;
    if (oldDelegate.galleryColumns != galleryColumns ||
        oldDelegate.forceDetailed != forceDetailed ||
        oldDelegate.windowWidth != windowWidth ||
        oldDelegate.scale != scale ||
        oldDelegate.useBriefMode != useBriefMode) {
      return true;
    }
    return false;
  }
}

class SliverLazyToBoxAdapter extends StatelessWidget {
  /// Creates a sliver that contains a single box widget which can be lazy loaded.
  const SliverLazyToBoxAdapter({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SliverList.list(children: [SizedBox(), child]);
  }
}

class SliverAnimatedVisibility extends StatelessWidget {
  const SliverAnimatedVisibility({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var child = visible ? this.child : const SizedBox.shrink();

    return SliverToBoxAdapter(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: child,
      ),
    );
  }
}
