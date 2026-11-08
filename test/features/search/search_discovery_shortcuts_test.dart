import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/search/search_discovery_shortcuts.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:venera_unified/foundation/global_preference_store.dart';

void _prepare() {
  final root = Directory.systemTemp.createTempSync('search-discovery-');
  App.dataPath = root.path;
  final previous = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
  addTearDown(() {
    previous.forEach((key, value) => appdata.settings[key] = value);
    root.deleteSync(recursive: true);
  });
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: const [SearchDiscoveryShortcutsSliver()],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the shortcut area stays hidden while the preference is off', (
    tester,
  ) async {
    _prepare();
    GlobalPreferenceStore(
      appdata.settings,
    ).write(DiscoveryPreferences.searchDiscoveryShortcuts, false);

    await _pump(tester);

    expect(find.text('Explore'), findsNothing);
    expect(find.text('Categories'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('both entries appear once the preference is on', (tester) async {
    _prepare();
    GlobalPreferenceStore(
      appdata.settings,
    ).write(DiscoveryPreferences.searchDiscoveryShortcuts, true);

    await _pump(tester);

    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('Categories'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('turning the preference on updates the page in place', (
    tester,
  ) async {
    _prepare();
    GlobalPreferenceStore(
      appdata.settings,
    ).write(DiscoveryPreferences.searchDiscoveryShortcuts, false);
    await _pump(tester);
    expect(find.text('Explore'), findsNothing);

    GlobalPreferenceStore(
      appdata.settings,
    ).write(DiscoveryPreferences.searchDiscoveryShortcuts, true);
    await tester.pumpAndSettle();

    expect(find.text('Explore'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
