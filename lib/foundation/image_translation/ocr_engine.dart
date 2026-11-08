import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:venera_unified/foundation/app.dart';
import 'ocr_models.dart';
import 'ocr_types.dart';
import 'ocr_worker.dart';

/// On-demand Japanese OCR for one reader page.
///
/// Decodes the page image, ships it to a worker isolate ([runOcrPage]) and
/// returns the recognized blocks. One shot per call: models are ensured first
/// (downloaded on first use), ORT sessions open inside the isolate and close
/// when the call finishes.
abstract class OcrEngine {
  /// 第一页验证后记住的、NNAPI 输出可信的模型路径。
  static final _verifiedModels = <String>{};

  /// 任一次比对失败后，后续页面直接走 CPU。
  static bool _accelerationRejected = false;

  /// Recognizes [imageBytes] (any format `package:image` decodes).
  ///
  /// [onDownloadProgress] reports model-download progress on first use, with
  /// the same (index, count, received, total) shape as [ensureOcrModels].
  /// Throws [OcrModelException] when models cannot be fetched or verified,
  /// and a readable [Exception] when the ONNX Runtime library is missing.
  static Future<List<OcrBlock>> recognizePage(
    Uint8List imageBytes, {
    void Function(int index, int count, int received, int total)?
    onDownloadProgress,
  }) async {
    var paths = await ensureOcrModels(onProgress: onDownloadProgress);
    var decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw Exception('Could not decode the page image for OCR.');
    }
    var rgba = decoded.getBytes(order: img.ChannelOrder.rgba);
    var transferable = TransferableTypedData.fromList([
      Uint8List.sublistView(rgba),
    ]);
    var request = OcrPageRequest(
      pixels: transferable,
      width: decoded.width,
      height: decoded.height,
      detector: paths.detector,
      recModel: paths.recModel,
      recDict: paths.recDict,
      forceCpu: _accelerationRejected,
      verifiedModels: {..._verifiedModels},
    );
    try {
      var outcome = await Isolate.run(() => runOcrPage(request));
      _verifiedModels.addAll(outcome.verifiedModels);
      if (outcome.accelerationRejected) {
        _accelerationRejected = true;
      }
      return outcome.blocks;
    } catch (e) {
      throw Exception(_readableError(e));
    }
  }

  static String _readableError(Object e) {
    var text = e.toString();
    if (text.contains('Failed to load ONNX Runtime library')) {
      // The HarmonyOS HAP ships no ONNX Runtime yet, so "reinstall and retry"
      // would be a lie there: the library is genuinely absent from this build.
      if (App.isOhos) {
        return 'Image translation is unavailable on this HarmonyOS build: '
            'it needs the ONNX Runtime library, which the experimental HAP '
            'does not bundle yet.';
      }
      return 'OCR is unavailable: the ONNX Runtime library is missing. '
          'Reinstall the app and retry.';
    }
    return 'OCR failed: $e';
  }
}
