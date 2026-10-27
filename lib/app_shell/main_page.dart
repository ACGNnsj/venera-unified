import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_unified/components/window_frame.dart';
import 'package:venera_unified/features/discovery/discovery.dart';
import 'package:venera_unified/features/favorites/favorites.dart';
import 'package:venera_unified/features/search/search.dart';
import 'package:venera_unified/features/settings/settings.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:venera_unified/foundation/global_preference_store.dart';
import 'package:venera_unified/foundation/launcher_icon.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/tray.dart';
import 'package:window_manager/window_manager.dart';

import '../components/navigation_bar.dart';
import 'package:venera_unified/routing/app_navigation.dart';
import '../foundation/context.dart';
import 'home_page.dart';
import 'tasks/tasks_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  late final NaviObserver _observer;

  GlobalKey<NavigatorState>? _navigatorKey;

  void to(Widget Function() widget, {bool preventDuplicate = false}) async {
    if (preventDuplicate) {
      var page = widget();
      if ("/${page.runtimeType}" == _observer.routes.last.toString()) return;
    }
    _navigatorKey!.currentContext!.to(widget);
  }

  @override
  void initState() {
    _observer = NaviObserver();
    _navigatorKey = GlobalKey();
    appNavigation.mainNavigatorKey = _navigatorKey;
    index = int.parse(
      GlobalPreferenceStore(
        appdata.settings,
      ).read(DiscoveryPreferences.initialPage),
    );
    super.initState();
  }

  final _pages = [
    const HomePage(),
    const FavoritesPage(key: PageStorageKey('favorites')),
    const ExplorePage(key: PageStorageKey('explore')),
    const CategoriesPage(key: PageStorageKey('categories')),
  ];

  var index = 0;

  @override
  Widget build(BuildContext context) {
    return _TrayBinding(
      child: NaviPane(
        initialPage: index,
        observer: _observer,
        navigatorKey: _navigatorKey!,
        paneItems: [
          PaneItemEntry(
            label: 'Home'.tl,
            icon: Icons.home_outlined,
            activeIcon: Icons.home,
          ),
          PaneItemEntry(
            label: 'Favorites'.tl,
            icon: Icons.local_activity_outlined,
            activeIcon: Icons.local_activity,
          ),
          PaneItemEntry(
            label: 'Explore'.tl,
            icon: Icons.explore_outlined,
            activeIcon: Icons.explore,
          ),
          PaneItemEntry(
            label: 'Categories'.tl,
            icon: Icons.category_outlined,
            activeIcon: Icons.category,
          ),
        ],
        onPageChanged: (i) {
          setState(() {
            index = i;
          });
        },
        paneActions: [
          if (index != 0)
            PaneActionEntry(
              icon: Icons.search,
              label: "Search".tl,
              onTap: () {
                to(() => const SearchPage(), preventDuplicate: true);
              },
            ),
          PaneActionEntry(
            icon: Icons.task_alt_outlined,
            label: "Tasks".tl,
            onTap: () {
              to(() => const TasksPage(), preventDuplicate: true);
            },
          ),
          PaneActionEntry(
            icon: Icons.settings,
            label: "Settings".tl,
            onTap: () {
              to(() => const SettingsPage(), preventDuplicate: true);
            },
          ),
        ],
        pageBuilder: (index) {
          return _pages[index];
        },
      ),
    );
  }
}

/// Binds the system tray to the window close pipeline.
///
/// Lives under [WindowFrame] so it can register a close guard: while the
/// tray is enabled, every close request (title-bar button, Alt+F4, taskbar)
/// hides the window into the tray instead of exiting. Quitting from the tray
/// menu unregisters the guard first and requests a normal close, so exit
/// tasks and finalization still run. Inert on non-Windows platforms and
/// before sign-in (this page is not mounted on the auth route).
class _TrayBinding extends StatefulWidget {
  const _TrayBinding({required this.child});

  final Widget child;

  @override
  State<_TrayBinding> createState() => _TrayBindingState();
}

class _TrayBindingState extends State<_TrayBinding> {
  WindowFrameController? _frame;
  bool _guarded = false;
  int _syncGeneration = 0;
  bool _launcherIconApplied = false;

  bool _wantsTray() =>
      App.isWindows &&
      GlobalPreferenceStore(
        appdata.settings,
      ).read(AppPreferences.minimizeToTray);

  @override
  void initState() {
    super.initState();
    unawaited(TrayController.instance.init());
    TrayController.instance.onQuitRequest = _quit;
    appdata.settings.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (App.isDesktop) {
      _frame = WindowFrame.of(context);
    }
    _sync();
    // Re-apply the stored launcher icon to the live window once it is ready.
    // No-op off Windows; guarded because dependencies can change repeatedly.
    if (!_launcherIconApplied) {
      _launcherIconApplied = true;
      unawaited(LauncherIconService.applyForStartup());
    }
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_sync);
    if (_guarded) {
      _frame?.removeCloseListener(_guard);
      _guarded = false;
    }
    if (identical(TrayController.instance.onQuitRequest, _quit)) {
      TrayController.instance.onQuitRequest = null;
    }
    super.dispose();
  }

  /// Close guard: hide into the tray and veto the close. Registered only
  /// after the tray icon exists, so the window can never vanish without one.
  bool _guard() {
    unawaited(TrayController.instance.hideToTray());
    return false;
  }

  void _sync() {
    unawaited(_syncAsync(++_syncGeneration));
  }

  Future<void> _syncAsync(int generation) async {
    final frame = _frame;
    if (!mounted || frame == null) return;
    final want = _wantsTray();
    await TrayController.instance.setEnabled(want);
    if (!mounted || generation != _syncGeneration) return;
    if (want && !_guarded) {
      frame.addCloseListener(_guard);
      _guarded = true;
    } else if (!want && _guarded) {
      frame.removeCloseListener(_guard);
      _guarded = false;
    }
  }

  Future<void> _quit() async {
    if (_guarded) {
      _frame?.removeCloseListener(_guard);
      _guarded = false;
    }
    // preventClose stays on: this only fires onWindowClose, and _onClose runs
    // the full graceful pipeline (exit tasks, finalize, exit).
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
