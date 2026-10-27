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
                child: split ? _buildWideLayout() : _buildNarrowLayout(),
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

  /// 窄档：现结构逐像素不变（零回归线）。
  Widget _buildNarrowLayout() {
    final split = favoritesUsesSplitPane(context.width);
    return Stack(
      children: [
        AnimatedPositioned(
          left: split ? 0 : -_kLeftBarWidth,
          top: 0,
          bottom: 0,
          duration: const Duration(milliseconds: 200),
          child: _buildSidebar().fixWidth(_kLeftBarWidth),
        ),
        Positioned(
          top: 0,
          left: split ? _kLeftBarWidth : 0,
          right: 0,
          bottom: 0,
          child: buildBody(),
        ),
      ],
    );
  }

  /// 宽档：weight 排布 + 空右栏归零（抄 miuix FavoritesSplitPaneHost）。
  ///
  /// 左栏宽由 [favoritesPaneWidths] 给（含 360 封顶），已选 1:2、未选 3:0；
  /// 右栏权重归零时不组合那一格（阈值 0.5dp，动画尾帧直接消失）。
  Widget _buildWideLayout() {
    final detailOpen = folder != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final (listTarget, _) = favoritesPaneWidths(
          totalWidth: totalWidth,
          detailOpen: detailOpen,
        );
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: listTarget),
          duration: const Duration(milliseconds: 200),
          builder: (context, listWidth, _) {
            final clampedList = listWidth.clamp(0.0, totalWidth).toDouble();
            final detailWidth = totalWidth - clampedList;
            return Row(
              children: [
                SizedBox(width: clampedList, child: _buildSidebar()),
                if (detailWidth > 0.5)
                  SizedBox(width: detailWidth, child: _buildDetailBody()),
              ],
            );
          },
        );
      },
    );
  }

  /// 宽档右栏内容。收栏那一瞬右栏还在往 0 长回去，内容不许先空掉 ——
  /// 所以关掉时仍按上一帧画（抄 miuix shownKey）。
  Widget _buildDetailBody() {
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

  Widget buildBody() {
    // 沿用旧逻辑：进页时发现持久化的网络夹已消失，当场丢掉回到未选中。
    if (folder != null && isNetwork && getFavoriteDataOrNull(folder!) == null) {
      folder = null;
    }
    return _buildBodyContent(isNetwork, folder);
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
