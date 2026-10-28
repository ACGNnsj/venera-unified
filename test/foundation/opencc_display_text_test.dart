import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:venera_unified/foundation/opencc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final key = AppearancePreferences.convertTraditionalToSimplified.key;

  test('displayText converts only when the appearance switch is on', () async {
    await OpenCC.init();
    final previous = appdata.settings[key];
    addTearDown(() => appdata.settings[key] = previous);

    appdata.settings[key] = false;
    expect(OpenCC.displayText('漫畫漢語'), '漫畫漢語');
    expect('漫畫漢語'.displayText, '漫畫漢語');

    appdata.settings[key] = true;
    expect(OpenCC.displayText('漫畫漢語'), '漫画汉语');
    expect('漫畫漢語'.displayText, '漫画汉语');
  });

  test('displayText leaves missing or non-true values untouched', () async {
    await OpenCC.init();
    final previous = appdata.settings[key];
    addTearDown(() => appdata.settings[key] = previous);

    for (final value in [null, 'yes', 1]) {
      appdata.settings[key] = value;
      expect(OpenCC.displayText('漫畫'), '漫畫');
      expect('漫畫'.displayText, '漫畫');
    }
  });
}
