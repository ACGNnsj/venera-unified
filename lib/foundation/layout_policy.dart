/// 收藏页「文件夹-内容」双栏的判据层（B7，复刻 miuix FavoritesSplitPanePolicy）。
///
/// 为什么判据要单独一颗文件：12 处散落的 `width <= 720` / `width < 720`
/// 比较在恰好 720dp 处互相打架（汉堡按 `<=` 出、标题点击按 `<` 关），
/// 收口到此处的纯函数后由单测钉住（test/foundation/layout_policy_test.dart）。
///
/// ## 两把尺，而且是故意的
///
/// - 导航形态走 consts.dart 的 changePoint/changePoint2（600/1300，`>`，
///   照 Flutter 祖本）：判据对齐的第一方是「手机档」；
/// - 收藏分栏走 [favoritesSplitPaneBreakpoint]（720，`>`）：判据对齐的第一方是
///   「手机横屏（740~800dp 常见）仍走单栏」这一既有产品行为。
///
/// 照 miuix 的方法论（FavoritesSplitPanePolicy.kt:28-31）：判据要对齐的第一方
/// 不同，就不该硬凑成同一把尺。不要把这里的 720 「顺手统一」成 600 ——
/// 那会让手机横屏进双栏，是产品行为变更，不在本票范围。
///
/// 840 不引入：它在 miuix 只为三栏（favoritesUsesThreePanes）存在，
/// 而三栏在 miuix 自身是零消费点的死代码，本票不抄。
library;

import 'dart:math';

/// 收藏分栏断点：窗口宽大于此值进双栏，等于此值仍是单栏。
const favoritesSplitPaneBreakpoint = 720.0;

/// 双栏下左栏（文件夹列表）的最大宽度；超出部分归右栏。
///
/// miuix 没有这条（Compose 平板窗不够宽，1/3 恒合理）；unified 有桌面端，
/// 1600dp 窗的 1/3（533dp）摆收藏夹名列表过宽，故封顶。
const favoritesListPaneMaxWidth = 360.0;

/// 收藏页在给定窗口宽下要不要进「文件夹 + 内容」双栏。
///
/// - `<= 720` → **false**：走现结构（窄档代码路径逐像素不变，零回归线）；
/// - `> 720` → **true**：左栏文件夹、右栏内容。
bool favoritesUsesSplitPane(double windowWidth) =>
    windowWidth > favoritesSplitPaneBreakpoint;

/// 双栏两栏各占多少重量（`列表 to 内容`）。
///
/// - 内容**打开**时 `1 to 2`；
/// - 内容**没选中**时 `3 to 0` —— 右栏给 0 而不是「很窄」，
///   宿主直接不组合那一格，占宽与空白板一起消失。
(double, double) favoritesPaneWeights({required bool detailOpen}) =>
    detailOpen ? (1.0, 2.0) : (3.0, 0.0);

/// 双栏两栏各占多少像素（`列表 to 内容`）。
///
/// 在 [favoritesPaneWeights] 的比例上给左栏加
/// [favoritesListPaneMaxWidth] 封顶，多余宽度归右栏。
(double, double) favoritesPaneWidths({
  required double totalWidth,
  required bool detailOpen,
}) {
  if (totalWidth <= 0) return (0.0, 0.0);
  if (!detailOpen) return (totalWidth, 0.0);
  final listWidth = min(totalWidth / 3.0, favoritesListPaneMaxWidth);
  return (listWidth, totalWidth - listWidth);
}
