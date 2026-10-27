import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/components/night_mode_overlay.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/application_preferences.dart';

Widget _harness() => MaterialApp(
  home: NightModeOverlay(child: const Scaffold(body: Text('内容'))),
);

void main() {
  tearDown(() {
    appdata.settings[AppearancePreferences.nightMode.key] = null;
  });

  testWidgets('默认关闭时不加滤镜', (tester) async {
    appdata.settings[AppearancePreferences.nightMode.key] = null;
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byType(ColorFiltered), findsNothing);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('打开后整树套上暖色滤镜', (tester) async {
    appdata.settings[AppearancePreferences.nightMode.key] = true;
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final filtered = tester.widget<ColorFiltered>(find.byType(ColorFiltered));
    expect(filtered.colorFilter, NightModeOverlay.filter);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('跑起来之后再关掉会立刻恢复', (tester) async {
    appdata.settings[AppearancePreferences.nightMode.key] = true;
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    expect(find.byType(ColorFiltered), findsOneWidget);

    appdata.settings[AppearancePreferences.nightMode.key] = false;
    await tester.pumpAndSettle();
    expect(find.byType(ColorFiltered), findsNothing);
  });
}
