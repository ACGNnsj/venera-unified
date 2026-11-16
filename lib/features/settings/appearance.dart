import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:flutter/material.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/components/scroll.dart';
import 'package:venera_unified/features/settings/home_layout.dart';
import 'package:venera_unified/features/settings/setting_components.dart';
import 'package:venera_unified/features/settings/theme_color_dialog.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/global_preference_store.dart';
import 'package:venera_unified/foundation/theme_colors.dart';
import 'package:venera_unified/routing/app_navigation.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({super.key});

  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  Future<void> editColor() async {
    final store = GlobalPreferenceStore(appdata.settings);
    final initial = resolveThemeColor(
      'custom',
      store.read(AppearancePreferences.customThemeColor).toInt(),
    );
    final color = await showDialog<Color>(
      context: context,
      builder: (_) => ThemeColorDialog(initialColor: initial),
    );
    if (color == null || !mounted) return;
    store.write(AppearancePreferences.customThemeColor, color.toARGB32());
    await appdata.saveData();
    if (!mounted) return;
    setState(() {});
    await App.init();
    appNavigation.forceRebuild();
  }

  @override
  Widget build(BuildContext context) {
    final customColor = resolveThemeColor(
      'custom',
      GlobalPreferenceStore(
        appdata.settings,
      ).read(AppearancePreferences.customThemeColor).toInt(),
    );
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
            "deepPurple": "Deep purple".tl,
            "indigo": "Indigo".tl,
            "blue": "Blue".tl,
            "lightBlue": "Light blue".tl,
            "cyan": "Cyan".tl,
            "teal": "Teal".tl,
            "green": "Green".tl,
            "lightGreen": "Light green".tl,
            "lime": "Lime".tl,
            "yellow": "Yellow".tl,
            "amber": "Amber".tl,
            "orange": "Orange".tl,
            "deepOrange": "Deep orange".tl,
            "brown": "Brown".tl,
            "blueGrey": "Blue grey".tl,
            "custom": "Custom".tl,
          },
          onChanged: () async {
            await App.init();
            appNavigation.forceRebuild();
          },
        ).toSliver(),
        ListTile(
          leading: CircleAvatar(radius: 14, backgroundColor: customColor),
          title: Text('Custom theme color'.tl),
          subtitle: Text(themeColorHex(customColor)),
          trailing: const Icon(Icons.chevron_right),
          onTap: editColor,
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
        ListTile(
          title: Text("Home Page Layout".tl),
          subtitle: Text("Long press and drag to reorder.".tl),
          leading: const Icon(Icons.dashboard_outlined),
          trailing: const Icon(Icons.arrow_right),
          onTap: () {
            context.to(() => const HomeLayoutSettings());
          },
        ).toSliver(),
      ],
    );
  }
}
