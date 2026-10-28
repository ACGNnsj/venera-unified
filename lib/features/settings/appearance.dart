import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:flutter/material.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/components/scroll.dart';
import 'package:venera_unified/features/settings/setting_components.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/routing/app_navigation.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({super.key});

  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Appearance".tl)),
        SelectSetting.preference(
          title: "Theme Mode".tl,
          preference: AppearancePreferences.themeMode,
          optionTranslation: {
            "system": "System".tl,
            "light": "Light".tl,
            "dark": "Dark".tl,
          },
          onChanged: () async {
            appNavigation.forceRebuild();
          },
        ).toSliver(),
        SliderSetting.preference(
          title: "UI font scale".tl,
          preference: AppearancePreferences.uiFontScale,
          valueFormatter: (value) => '${(value * 100).round()}%',
          onChanged: () {
            appNavigation.forceRebuild();
          },
        ).toSliver(),
        SelectSetting.preference(
          title: "Theme Color".tl,
          preference: AppearancePreferences.color,
          optionTranslation: {
            "system": "System".tl,
            "red": "Red".tl,
            "pink": "Pink".tl,
            "purple": "Purple".tl,
            "green": "Green".tl,
            "orange": "Orange".tl,
            "blue": "Blue".tl,
          },
          onChanged: () async {
            await App.init();
            appNavigation.forceRebuild();
          },
        ).toSliver(),
        SliderSetting.preference(
          title: "Comment Font Size".tl,
          preference: AppearancePreferences.commentFontSize,
          valueFormatter: (value) => value.toInt().toString(),
          onChanged: () {
            setState(() {});
          },
        ).toSliver(),
        SwitchSetting.preference(
          title: "Night Mode".tl,
          preference: AppearancePreferences.nightMode,
          subtitle: "Cuts blue light for reading in the dark".tl,
          onChanged: () {
            setState(() {});
          },
        ).toSliver(),
        SwitchSetting.preference(
          title: "Convert traditional to simplified".tl,
          preference: AppearancePreferences.convertTraditionalToSimplified,
          subtitle:
              "Display comic titles and chapters in simplified Chinese".tl,
          onChanged: () {
            appNavigation.forceRebuild();
          },
        ).toSliver(),
      ],
    );
  }
}
