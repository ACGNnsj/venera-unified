import 'package:venera_unified/features/favorites/favorites_scope.dart';
import 'dart:math';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/components/settings_save_state.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/layout_policy.dart';
import 'package:venera_unified/features/comic_source/comic_source.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';
import 'package:venera_unified/features/favorites/favorites_constants.dart';
import 'package:venera_unified/features/favorites/local_favorites_page.dart';
import 'package:venera_unified/features/favorites/network_favorites_page.dart';
import 'package:venera_unified/features/favorites/side_bar.dart';

const _kLeftBarWidth = 256.0;

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends SettingsSaveState<FavoritesPage> {
  Route<void>? _folderSelector;
  String? folder;

  bool isNetwork = false;

  /// 收栏动画进行中右栏按上一帧画的内容（抄 miuix lastDetailKey）。
  bool _lastDetailIsNetwork = false;
  String? _lastDetailFolder;

  FolderList? folderList;

  void setFolder(bool isNetwork, String? folder) {
    if (!acceptsSettingsChanges) return;
    // 无条件覆盖（含 null）：删夹流把 null 持久化后，上一帧就是已不存在的
    // 夹子，不许再画；只有 PopScope 收栏（不经此处）会保留上一帧。
    _lastDetailIsNetwork = isNetwork;
    _lastDetailFolder = folder;
    setState(() {
      this.isNetwork = isNetwork;
      this.folder = folder;
    });
    folderList?.update();
    saveSetting(
      'favoriteFolder',
      () => appdata.updateImplicit((draft) {
        draft['favoriteFolder'] = {'name': folder, 'isNetwork': isNetwork};
      }),
    );
  }

  @override
  void initState() {
    var data = appdata.implicitData['favoriteFolder'];
    if (data != null) {
      folder = data['name'];
      isNetwork = data['isNetwork'] ?? false;
    }
    if (folder != null &&
        !isNetwork &&
        folder != localAllFolderLabel &&
        !FavoritesScope.read(context).existsFolder(folder!)) {
      folder = null;
    }
    _lastDetailIsNetwork = isNetwork;
    _lastDetailFolder = folder;
    super.initState();
  }

  /// 收栏（宽档返回键）：只清内存，不写回 favoriteFolder 偏好。
  ///
  /// 收栏是临时导航动作（对标 miuix detailKey 的 session 态），下次进页仍按
  /// 用户上次选中的文件夹打开。
  void _collapseDetailPane() {
    if (folder == null) return;
    setState(() {
      folder = null;
    });
    folderList?.update();
  }

  @override
  Widget build(BuildContext context) {
    final split = favoritesUsesSplitPane(context.width);
    return protectSettings(
      PopScope(
        canPop: !(split && folder != null),
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _collapseDetailPane();
        },
        child: Column(
          children: [
            if (savingSettings || hasSettingsSaveError) settingsSaveStatus,
            Expanded(
              child: IconTheme(
                data: IconThemeData(
                  color: Theme.of(context).colorScheme.secondary,
                ),
                child: _buildPaneLayout(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar() {
    return FavoritesFolderSidebar(
      selectedFolder: folder,
      isNetworkSelected: isNetwork,
      onFolderSelected: setFolder,
      onFolderListReady: (list) {
        folderList = list;
      },
    );
  }

  /// 窄/宽统一骨架：永远是同一棵 Stack，窄宽只换数值。
  ///
  /// 教训（rc.4 favorites-suite-repair）：B7 初版窄用 Stack、宽用 Row，
  /// 过断点整棵子树 remount —— LocalFavoritesPage 的 context 当场卸载，
  /// 之前从它身上 capture 的 WindowSelectionTask（owner.active）永久变 false，
  /// 排序页的 _canEdit 跟着死，拖拽全部静默 no-op。现在两档同构，
  /// 过断点只是数值动画，element 与 state 原位保留。
  ///
  /// 几何（和 B7 初版逐像素一致）：
  /// - 窄档：侧栏滑出屏幕外（-256），内容全宽；
  /// - 宽档：侧栏 0 起、宽走 [favoritesPaneWidths]（1:2，360 封顶），
  ///   内容占剩下；未选中时 3:0，右栏归零。
  ///
  /// 右栏常驻组合（含 0 宽稳态），视觉上和「不组合」完全一致，
  /// 但树是稳定的：选中后下一帧内容页必在树上（无动画阈值空窗），
  /// 未选中时 Unselected 占位也在树上（0 宽不可见）。上游 port 测试
  /// （favorites_view_persistence）断言的就是这份存在性，不许悄悄改弱。
  Widget _buildPaneLayout() {
    final detailOpen = folder != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final split = favoritesUsesSplitPane(totalWidth);
        final (listTarget, _) = favoritesPaneWidths(
          totalWidth: totalWidth,
          detailOpen: detailOpen,
        );
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: split ? 0.0 : -_kLeftBarWidth),
          duration: const Duration(milliseconds: 200),
          builder: (context, sidebarLeft, _) => TweenAnimationBuilder<double>(
            tween: Tween<double>(end: split ? listTarget : _kLeftBarWidth),
            duration: const Duration(milliseconds: 200),
            builder: (context, listWidth, _) {
              final sidebarWidth = listWidth.clamp(0.0, totalWidth).toDouble();
              final bodyLeft = split ? sidebarWidth : 0.0;
              return Stack(
                children: [
                  Positioned(
                    left: sidebarLeft,
                    top: 0,
                    bottom: 0,
                    width: sidebarWidth,
                    child: _buildSidebar(),
                  ),
                  // 右栏常驻组合：0 宽稳态下占位仍在树上（不可见），
                  // 选中后下一帧内容页即存在，无阈值空窗。
                  Positioned(
                    left: bodyLeft,
                    top: 0,
                    bottom: 0,
                    right: 0,
                    child: _buildDetailBody(),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 右栏内容。收栏那一瞬右栏还在往 0 长回去，内容不许先空掉 ——
  /// 所以关掉时仍按上一帧画（抄 miuix shownKey）。
  Widget _buildDetailBody() {
    // 沿用旧逻辑：进页时发现持久化的网络夹已消失，当场丢掉回到未选中。
    if (folder != null && isNetwork && getFavoriteDataOrNull(folder!) == null) {
      folder = null;
    }
    if (folder != null) return _buildBodyContent(isNetwork, folder);
    return _buildBodyContent(_lastDetailIsNetwork, _lastDetailFolder);
  }

  void showFolderSelector() {
    if (!acceptsSettingsChanges || _folderSelector != null) return;
    final origin = ModalRoute.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = PageRouteBuilder<void>(
      barrierDismissible: true,
      fullscreenDialog: true,
      opaque: false,
      barrierColor: Colors.black.toOpacity(0.36),
      pageBuilder: (context, animation, secondary) {
        return Align(
          alignment: Alignment.centerLeft,
          child: Material(
            child: SizedBox(
              width: min(300, context.width - 16),
              child: FavoritesFolderSidebar(
                withAppbar: true,
                selectedFolder: folder,
                isNetworkSelected: isNetwork,
                onFolderSelected: (network, name) {
                  if (mounted &&
                      identical(ModalRoute.of(this.context), origin)) {
                    setFolder(network, name);
                  }
                },
                onFolderListReady: (list) {
                  folderList = list;
                },
                onSelected: () {
                  if (context.mounted &&
                      ModalRoute.of(context)?.isCurrent == true) {
                    Navigator.of(context).maybePop();
                  }
                },
              ),
            ),
          ),
        );
      },
      transitionsBuilder: (context, animation, secondary, child) {
        var offset = Tween<Offset>(
          begin: const Offset(-1, 0),
          end: const Offset(0, 0),
        );
        return SlideTransition(
          position: offset.animate(
            CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn),
          ),
          child: child,
        );
      },
    );
    _folderSelector = route;
    navigator.push(route).whenComplete(() {
      if (identical(_folderSelector, route)) _folderSelector = null;
    });
  }

  @override
  void dispose() {
    final route = _folderSelector;
    _folderSelector = null;
    scheduleMicrotask(() {
      final navigator = route?.navigator;
      if (navigator?.mounted == true && route!.isActive) {
        navigator!.removeRoute(route);
      }
    });
    super.dispose();
  }

  Widget _buildBodyContent(bool isNetwork, String? folder) {
    if (folder == null) {
      return CustomScrollView(
        slivers: [
          SliverAppbar(
            leading: Tooltip(
              message: "Folders".tl,
              child: favoritesUsesSplitPane(context.width)
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.menu),
                      color: context.colorScheme.primary,
                      onPressed: showFolderSelector,
                    ),
            ),
            title: GestureDetector(
              onTap: favoritesUsesSplitPane(context.width)
                  ? null
                  : showFolderSelector,
              child: Text("Unselected".tl),
            ),
          ),
        ],
      );
    }
    if (!isNetwork) {
      return LocalFavoritesPage(
        folder: folder,
        key: PageStorageKey("local_$folder"),
        showFolders: showFolderSelector,
        onFolderSelected: setFolder,
        updateFolderList: () {
          folderList?.updateFolders();
        },
      );
    } else {
      var favoriteData = getFavoriteDataOrNull(folder);
      if (favoriteData == null) {
        // 上一帧专属：收栏动画尾帧里过期内容按未选中画，不碰 live 字段。
        return _buildBodyContent(false, null);
      } else {
        return NetworkFavoritePage(
          favoriteData,
          key: PageStorageKey("network_$folder"),
          showFolders: showFolderSelector,
        );
      }
    }
  }
}
