import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/components/rich_comment_content.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/application_preferences.dart';

Widget _harness(Widget child) =>
    MaterialApp(home: Scaffold(body: DefaultTextStyle(style: const TextStyle(fontSize: 99), child: child)));

TextSpan _spanOf(WidgetTester tester) {
  final selectable = tester.widget<SelectableText>(find.byType(SelectableText));
  return selectable.textSpan!;
}

void main() {
  tearDown(() {
    appdata.settings[AppearancePreferences.commentFontSize.key] = null;
  });

  testWidgets('评论字号取偏好值，不跟随外层 DefaultTextStyle', (tester) async {
    appdata.settings[AppearancePreferences.commentFontSize.key] = null;
    await tester.pumpWidget(_harness(const RichCommentContent(text: '普通评论')));
    await tester.pumpAndSettle();

    expect(_spanOf(tester).style!.fontSize, 14);
  });

  testWidgets('改偏好后评论字号跟着变', (tester) async {
    appdata.settings[AppearancePreferences.commentFontSize.key] = 22;
    await tester.pumpWidget(_harness(const RichCommentContent(text: '普通评论')));
    await tester.pumpAndSettle();

    expect(_spanOf(tester).style!.fontSize, 22);
  });
}
