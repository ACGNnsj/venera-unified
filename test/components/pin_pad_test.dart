import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/components/pin_pad.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('四位输满后回调一次', (tester) async {
    final entered = <String>[];
    await tester.pumpWidget(wrap(PinPad(onSubmitted: entered.add)));

    for (final digit in ['1', '2', '3']) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    expect(entered, isEmpty);

    await tester.tap(find.text('4'));
    await tester.pump();
    expect(entered, ['1234']);
  });

  testWidgets('退格能删掉一位', (tester) async {
    final entered = <String>[];
    await tester.pumpWidget(wrap(PinPad(onSubmitted: entered.add)));

    await tester.tap(find.text('9'));
    await tester.pump();
    await tester.tap(find.text('⌫'));
    await tester.pump();
    await tester.tap(find.text('1'));
    await tester.tap(find.text('2'));
    await tester.tap(find.text('3'));
    await tester.tap(find.text('4'));
    await tester.pump();

    expect(entered, ['1234']);
  });

  testWidgets('出现错误提示时清空已输入位', (tester) async {
    final entered = <String>[];
    await tester.pumpWidget(wrap(PinPad(onSubmitted: entered.add)));

    await tester.tap(find.text('1'));
    await tester.tap(find.text('2'));
    await tester.pump();

    await tester.pumpWidget(
      wrap(PinPad(onSubmitted: entered.add, error: '错了')),
    );
    await tester.pump();
    expect(find.text('错了'), findsOneWidget);

    // 清空后重新输满四位仍能回调一次完整序列。
    for (final digit in ['5', '6', '7', '8']) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    expect(entered, ['5678']);
  });
}
