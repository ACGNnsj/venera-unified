import 'dart:io';
import 'package:flutter/services.dart';
import 'package:venera_unified/foundation/harmonyos.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/file_interaction.dart' as interaction;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    HarmonyOS.debugIsCurrent = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HarmonyOS.channel, null);
    interaction.Share.canShareFiles = () => !App.isLinux;
    interaction.Share.usesClipboard = () => App.isDesktop;
  });

  test(
    'a platform without a share target reports it instead of dispatching',
    () async {
      interaction.Share.canShareFiles = () => false;
      await expectLater(
        interaction.Share.shareFile(
          data: Uint8List.fromList([1]),
          filename: 'page.png',
          mime: 'image/png',
        ),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  test(
    'HarmonyOS dispatches retained file and text via its native channel',
    () async {
      final root = Directory.systemTemp.createTempSync('harmony-share-');
      addTearDown(() {
        root.deleteSync(recursive: true);
      });
      App.cachePath = root.path;
      HarmonyOS.debugIsCurrent = true;
      final calls = <MethodCall>[];
      String? source;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HarmonyOS.channel, (call) async {
            calls.add(call);
            if (call.method == 'shareFile') {
              source = call.arguments['path'] as String;
              expect(File(source!).readAsBytesSync(), [1, 2, 3]);
            }
            return null;
          });
      await interaction.Share.shareFile(
        data: Uint8List.fromList([1, 2, 3]),
        filename: 'page.png',
        mime: 'image/png',
      );
      expect(File(source!).existsSync(), isTrue);
      expect(
        await interaction.Share.shareText('link'),
        interaction.ShareTextResult.shared,
      );
      expect(calls.map((call) => call.method), ['shareFile', 'shareText']);
      expect(calls.last.arguments, {'text': 'link'});
    },
  );

  test('text sharing copies to the clipboard when no target exists', () async {
    interaction.Share.usesClipboard = () => true;
    expect(
      await interaction.Share.shareText('link'),
      interaction.ShareTextResult.copied,
    );
  });
}
