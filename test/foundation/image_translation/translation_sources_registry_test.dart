import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/image_translation/translation_sources.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appdata.settings[TranslationSources.settingKey] = <dynamic>[];
  });

  group('TranslationSources', () {
    Map<String, dynamic> entry(String code, {String? model}) => {
      'code': code,
      'name': 'Name $code',
      'model': model ?? 'https://example.com/$code.onnx',
      'dict': 'https://example.com/$code.txt',
      'height': 48,
      'size': 100,
    };

    test('reads entries, skipping malformed ones and built-in codes', () {
      appdata.settings[TranslationSources.settingKey] = [
        entry('TH'),
        entry('th'),
        entry('zh-tw'),
        entry('ru', model: 'ftp://example.com/ru.onnx'),
        {'code': 'fr', 'name': ''},
        'corrupt',
        {...entry('fr'), 'height': 32},
      ];
      var custom = TranslationSources.custom;
      expect(custom.map((e) => e.code), ['th', 'fr']);
      expect(custom.last.inputHeight, 32);
      expect(TranslationSources.isTaken('auto'), isTrue);
      expect(TranslationSources.isTaken('zh-TW'), isTrue);
      expect(TranslationSources.isTaken('th'), isTrue);
      expect(TranslationSources.isTaken('de'), isFalse);
    });

    test('engine key follows the files, not the code', () {
      var a = CustomSourceLanguage.fromJson(entry('th'))!;
      var renamed = CustomSourceLanguage.fromJson({
        ...entry('th'),
        'name': 'ไทย',
      })!;
      var moved = CustomSourceLanguage.fromJson(
        entry('th', model: 'https://example.com/other.onnx'),
      )!;
      expect(renamed.engine, a.engine);
      expect(moved.engine, isNot(a.engine));
      expect(a.component.marker, isTrue);
    });

    test('folder hash is stable across versions', () {
      expect(modelHash('abc'), '1a47e90b');
    });
  });
}
