import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/image_translation/translation_models.dart';
import 'package:venera_unified/foundation/image_translation/translation_worker.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('translation_models_test');
    App.dataPath = tempDir.path;
  });

  tearDownAll(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('TranslationModels registry', () {
    test('all lists six components', () {
      expect(TranslationModels.all.length, 6);
      expect(TranslationModels.find('text_detector'), TranslationModels.detector);
      expect(TranslationModels.find('ocr_ja'), TranslationModels.ocrJa);
      expect(TranslationModels.find('nope'), isNull);
    });

    test('component paths live under translation_models', () {
      var dir = TranslationModels.detector.directory;
      expect(dir.contains('translation_models'), isTrue);
      expect(
        TranslationModels.detector.filePath('det.onnx').endsWith('det.onnx'),
        isTrue,
      );
    });

    test('nothing is installed in a fresh data dir', () {
      expect(TranslationModels.detector.isInstalled, isFalse);
      expect(TranslationModels.ocrJa.isInstalled, isFalse);
      expect(TranslationModels.isReadyFor('auto'), isFalse);
      expect(TranslationModels.isReadyFor('ja'), isFalse);
      expect(TranslationModels.isReadyFor('zh'), isFalse);
    });

    test('requiredFor auto needs only the detector', () {
      var required = TranslationModels.requiredFor('auto');
      expect(required.length, 1);
      expect(required.single.id, 'text_detector');
      expect(
        TranslationModels.requiredFor('ja').map((c) => c.id),
        contains('ocr_ja'),
      );
      expect(
        TranslationModels.requiredFor('zh-TW').map((c) => c.id),
        contains('ocr_zh_v5'),
      );
    });
  });

  group('resolveOcrEngines', () {
    test('auto lists installed line engines in order', () {
      expect(
        resolveOcrEngines('auto', installed: {'zh5', 'zh', 'en', 'ko'}),
        ['zh5', 'en', 'ko'],
      );
      expect(resolveOcrEngines('auto', installed: {}), isEmpty);
    });

    test('v5 replaces v4 when present', () {
      expect(
        resolveOcrEngines('zh', installed: {'zh5', 'zh'}),
        ['zh5'],
      );
      expect(resolveOcrEngines('zh', installed: {'zh'}), ['zh']);
    });

    test('single-language selections', () {
      expect(resolveOcrEngines('ja', installed: {'ja'}), ['ja']);
      expect(resolveOcrEngines('en', installed: {'en', 'ko'}), ['en']);
      expect(resolveOcrEngines('ko', installed: {'en'}), isEmpty);
    });

    test('unknown code uses the custom engine only', () {
      expect(
        resolveOcrEngines('xx', installed: {'custom_1234abcd'}, customEngine: 'custom_1234abcd'),
        ['custom_1234abcd'],
      );
      expect(resolveOcrEngines('xx', installed: {'en'}), isEmpty);
    });
  });

  group('workerPaths', () {
    test('empty install yields detector path and no engines', () {
      var paths = TranslationModels.workerPaths('auto');
      expect(paths.detector.endsWith('det.onnx'), isTrue);
      expect(paths.jaEncoder, isNull);
      expect(paths.jaDecoder, isNull);
      expect(paths.jaVocab, isNull);
      expect(paths.recModels, isEmpty);
      expect(paths.engines, isEmpty);
      expect(paths.recDicts, isEmpty);
    });
  });

  group('describeModelCheck', () {
    test('every failure has a message', () {
      for (var failure in ModelCheckFailure.values) {
        var message = describeModelCheck(
          ModelCheckException(failure, classes: 100, entries: 98),
        );
        expect(message.isNotEmpty, isTrue);
      }
      expect(
        const ModelCheckException(ModelCheckFailure.cannotRun).toString(),
        contains('cannotRun'),
      );
    });
  });

  group('TranslationModelStore', () {
    test('stateOf is stable per component', () {
      var store = TranslationModelStore.instance;
      expect(
        identical(store.stateOf(TranslationModels.detector), store.stateOf(TranslationModels.detector)),
        isTrue,
      );
      expect(store.stateOf(TranslationModels.detector).downloading, isFalse);
    });

    test('installed size is zero in a fresh data dir', () {
      expect(TranslationModelStore.instance.installedSizeBytes, 0);
    });
  });
}
