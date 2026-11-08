import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/file_interaction.dart' as interaction;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    interaction.Share.canShareFiles = () => !App.isLinux && !App.isOhos;
    interaction.Share.usesClipboard = () => App.isDesktop || App.isOhos;
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

  test('text sharing copies to the clipboard when no target exists', () async {
    interaction.Share.usesClipboard = () => true;
    expect(
      await interaction.Share.shareText('link'),
      interaction.ShareTextResult.copied,
    );
  });
}
