import 'package:flutter/material.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:venera_unified/foundation/global_preference_store.dart';

/// 夜览：在整棵界面树外面套一层暖色滤镜，压低蓝通道。
///
/// 只在用户打开「夜览」时生效，默认不干预渲染，所以不影响现有截图与测试基线。
class NightModeOverlay extends StatefulWidget {
  const NightModeOverlay({super.key, required this.child});

  final Widget child;

  /// 蓝通道保留比例；越小越黄。
  static const double blueScale = 0.82;

  /// 红绿通道各轻微衰减，避免整体发白。
  static const double greenScale = 0.97;

  /// 夜览开启时使用的颜色矩阵。
  static const ColorFilter filter = ColorFilter.matrix(<double>[
    1, 0, 0, 0, 0, //
    0, greenScale, 0, 0, 0, //
    0, 0, blueScale, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  State<NightModeOverlay> createState() => _NightModeOverlayState();
}

class _NightModeOverlayState extends State<NightModeOverlay> {
  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_refresh);
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final enabled = GlobalPreferenceStore(
      appdata.settings,
    ).read(AppearancePreferences.nightMode);
    if (!enabled) return widget.child;
    return ColorFiltered(
      colorFilter: NightModeOverlay.filter,
      child: widget.child,
    );
  }
}
