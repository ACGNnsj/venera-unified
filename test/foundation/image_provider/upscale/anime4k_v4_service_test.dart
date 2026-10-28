// B5 Anime4K v4 (official ACNet 2x) pure-logic unit tests.
// No platform channels are touched: init()/ensureModelAvailable() (path_provider)
// and native inference are deliberately NOT called here. Native behavior is
// covered by the assembleDebug build evidence instead.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_provider/upscale/anime4k_v4_model_manager.dart';
import 'package:venera_unified/foundation/image_provider/upscale/anime4k_v4_service.dart';

void main() {
  group('Anime4KV4ModelManager registry', () {
    test('single bundled ACNet model', () {
      final models = Anime4KV4ModelManager.getModels();
      expect(models, hasLength(1));
      final def = models.single;
      expect(def.id, 'anime4k_acnet');
      expect(def.fileName, 'anime4k_acnet.onnx');
      expect(def.scale, 2);
      expect(def.channels, 1);
      expect(def.bundledAssetPath, 'assets/models/anime4k_acnet.onnx');
    });

    test('selectedDef/modelFileName point at the bundled model', () {
      expect(Anime4KV4ModelManager.selectedDef.id, 'anime4k_acnet');
      expect(Anime4KV4ModelManager.modelFileName, 'anime4k_acnet.onnx');
    });

    test('validModelMinSize is 8KB', () {
      expect(Anime4KV4ModelManager.validModelMinSize, 8 * 1024);
    });

    test('isValidModelId / modelById fallback', () {
      expect(Anime4KV4ModelManager.isValidModelId('anime4k_acnet'), isTrue);
      expect(Anime4KV4ModelManager.isValidModelId('nope'), isFalse);
      expect(Anime4KV4ModelManager.modelById('nope').id, 'anime4k_acnet');
    });

    test('getModels returns an unmodifiable view', () {
      final models = Anime4KV4ModelManager.getModels();
      expect(
        () => models.add(
          const V4ModelDef(
            id: 'x',
            fileName: 'x.onnx',
            displayName: 'x',
            scale: 2,
            channels: 1,
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('Anime4KV4Service pure logic', () {
    test('channel and method names match the native contract', () {
      expect(Anime4KV4Service.channelName, 'venera/upscale');
      expect(Anime4KV4Service.upscaleMethod, 'upscale');
      expect(Anime4KV4Service.resetSessionMethod, 'resetSession');
    });

    test('shouldUseNnapi: 1-channel CPU only, 3-channel NNAPI first', () {
      expect(Anime4KV4Service.shouldUseNnapi(1), isFalse);
      expect(Anime4KV4Service.shouldUseNnapi(3), isTrue);
    });

    test('buildCacheKey pins model id and intensity', () {
      expect(
        Anime4KV4Service.buildCacheKey('anime4k_acnet', 'k', 1.0),
        'v4_anime4k_acnet_k_1.00',
      );
      expect(
        Anime4KV4Service.buildCacheKey('anime4k_acnet', 'k', 0.5),
        isNot(Anime4KV4Service.buildCacheKey('anime4k_acnet', 'k', 1.0)),
      );
    });

    test('singleton identity', () {
      expect(identical(Anime4KV4Service(), Anime4KV4Service.instance), isTrue);
    });

    test('isAvailable is false on non-Android hosts', () {
      expect(Anime4KV4Service.instance.isAvailable, isFalse);
    });

    test('processImage returns null on non-Android hosts', () async {
      final result = await Anime4KV4Service.instance.processImage(
        imageBytes: Uint8List(0),
        cacheKey: 'host-guard',
      );
      expect(result, isNull);
    });
  });
}
