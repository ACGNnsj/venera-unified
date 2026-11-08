import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/settings/image_translation.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';

void _prepare() {
  final root = Directory.systemTemp.createTempSync('image-translation-');
  App.dataPath = root.path;
  final previous = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
  addTearDown(() {
    previous.forEach((key, value) => appdata.settings[key] = value);
    root.deleteSync(recursive: true);
  });
}

Future<void> _pumpPage(WidgetTester tester) async {
  _prepare();
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: ImageTranslationSettings())),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('image translation settings renders all four sections', (
    tester,
  ) async {
    await _pumpPage(tester);

    expect(find.text('Image Translation'), findsWidgets);
    expect(find.text('Language & text removal'), findsOneWidget);
    expect(find.text('Translation providers'), findsOneWidget);
    expect(find.text('Glossary'), findsOneWidget);
    expect(
      find.text('Translation models', skipOffstage: false),
      findsOneWidget,
    );
    // Untouched install: no providers, no glossaries, model ids listed.
    expect(find.text('No providers yet'), findsOneWidget);
    expect(find.text('No glossaries yet', skipOffstage: false), findsOneWidget);
    expect(find.text('text_detector', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add provider dialog opens with openai fields', (tester) async {
    await _pumpPage(tester);

    await tester.tap(find.text('Add provider'));
    await tester.pumpAndSettle();

    expect(find.text('API URL'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
