import 'package:flutter/material.dart';
import 'package:venera_unified/components/navigation_bar.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/global_preference_store.dart';
import 'package:venera_unified/foundation/home_tabs.dart';
import 'package:venera_unified/foundation/translations.dart';

/// 搜索页顶部的可选快捷入口：去「发现」「分类」两个 Tab。
///
/// 只在 [DiscoveryPreferences.searchDiscoveryShortcuts] 打开时显示；关闭时返回零高度，
/// 搜索页的滚动内容与没有这个 Sliver 时逐像素一致。它不合并 Explore Tab，
/// 也不改动主导航，只是给搜索页补一条去发现页的路。
class SearchDiscoveryShortcutsSliver extends StatefulWidget {
  const SearchDiscoveryShortcutsSliver({super.key});

  @override
  State<SearchDiscoveryShortcutsSliver> createState() =>
      _SearchDiscoveryShortcutsSliverState();
}

class _SearchDiscoveryShortcutsSliverState
    extends State<SearchDiscoveryShortcutsSliver> {
  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(onSettingsChanged);
  }

  @override
  void dispose() {
    appdata.settings.removeListener(onSettingsChanged);
    super.dispose();
  }

  void onSettingsChanged() {
    if (mounted) setState(() {});
  }

  bool get enabled => GlobalPreferenceStore(
    appdata.settings,
  ).read(DiscoveryPreferences.searchDiscoveryShortcuts);

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(
          children: [
            Expanded(
              child: _entry(
                context,
                icon: Icons.explore_outlined,
                label: 'Explore'.tl,
                tab: HomeTabs.explore,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _entry(
                context,
                icon: Icons.category_outlined,
                label: 'Categories'.tl,
                tab: HomeTabs.categories,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entry(
    BuildContext context, {
    required IconData icon,
    required String label,
    required int tab,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openTab(context, tab),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 切到主面板的指定 Tab。
  ///
  /// 走 [NaviPaneState.updatePage]，与点主导航项同一条路径：先把压在上面的路由
  /// （搜索页自己）弹回收起，再切 Tab，所以不会出现「搜索页还在、Tab 已经换了」。
  void openTab(BuildContext context, int tab) {
    final pane = context.findAncestorStateOfType<NaviPaneState>();
    if (pane == null) {
      context.showMessage(message: 'Shortcut unavailable'.tl);
      return;
    }
    pane.updatePage(tab);
  }
}
