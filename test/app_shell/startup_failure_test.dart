import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_shell/startup_failure.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  Object? language;
  setUp(() {
    language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
  });
  tearDown(() => appdata.settings['language'] = language);

  Widget failure() => StartupFailureApp(
    error: StateError('attempt to write a readonly database'),
    stack: StackTrace.fromString(
      'Cookie: session=private-cookie\n#0 test startup',
    ),
  );

  testWidgets(
    'startup failure is visible and copies only redacted diagnostics',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(failure());
      await tester.pumpAndSettle();
      expect(find.text('Startup failed'), findsOneWidget);
      expect(find.textContaining('private-cookie'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      await tester.tap(find.text('Copy diagnostic details'));
      await tester.pumpAndSettle();
      expect(copied, contains('readonly database'));
      expect(copied, isNot(contains('private-cookie')));
      expect(find.text('Copied'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late clipboard response cannot update the retired failure page',
    (tester) async {
      final copying = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') await copying.future;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(failure());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy diagnostic details'));
      await tester.pumpWidget(const SizedBox());
      copying.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failure details remain scrollable on narrow large-text screens',
    (tester) async {
      tester.view.physicalSize = const Size(375, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(failure());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(SelectableText),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
