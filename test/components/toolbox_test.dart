import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/components/toolbox.dart';

void main() {
  testWidgets('toolbox sheet lists both image search entries', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showToolbox(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Tools'), findsOneWidget);
    expect(find.text('Image search [Search by Image Bot]'), findsOneWidget);
    expect(find.text('Image search [SauceNAO]'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
