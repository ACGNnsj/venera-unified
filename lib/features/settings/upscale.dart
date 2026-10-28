import 'package:flutter/material.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/components/scroll.dart';
import 'package:venera_unified/components/settings_save_state.dart';
import 'package:venera_unified/features/settings/setting_components.dart';
import 'package:venera_unified/foundation/image_provider/upscale/anime4k_v4_model_manager.dart';
import 'package:venera_unified/foundation/reader_preferences.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

/// Anime4K v4 超分设置页（阅读设置 → 超分入口进入，入口仅 Android 显示）。
///
/// 第一阶段仅内置官方 ACNet 2× 模型：两个开关 + 一行模型展示。
/// 模型选择/强度调节留待后续阶段；英文文案先行，
/// translation.json 登记由 lead 统一处理。
class UpscaleSetting extends StatefulWidget {
  const UpscaleSetting({super.key});

  @override
  State<UpscaleSetting> createState() => _UpscaleSettingState();
}

class _UpscaleSettingState extends SettingsSaveState<UpscaleSetting> {
  @override
  Widget build(BuildContext context) {
    return protectSettings(
      SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text("Image Upscaling".tl)),
          settingsSaveStatus.toSliver(),
          SwitchSetting.reader(
            title: "Enable image upscaling".tl,
            subtitle: "Enhance image clarity when reading".tl,
            preference: ReaderPreferences.upscaleEnabled,
          ).toSliver(),
          SwitchSetting.reader(
            title: "Upscale downloaded images".tl,
            subtitle: "Also process images saved to downloads".tl,
            preference: ReaderPreferences.upscaleApplyToDownloads,
          ).toSliver(),
          ListTile(
            title: Text("Upscale model".tl),
            subtitle: Text(Anime4KV4ModelManager.selectedDef.displayName),
          ).toSliver(),
        ],
      ),
    );
  }
}
