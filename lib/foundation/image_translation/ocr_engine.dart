import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

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
    );
    try {
      return await Isolate.run(() => runOcrPage(request));
    } catch (e) {
      throw Exception(_readableError(e));
    }
  }

  static String _readableError(Object e) {
    var text = e.toString();
    if (text.contains('Failed to load ONNX Runtime library')) {
      return 'OCR is unavailable: the ONNX Runtime library is missing. '
          'Reinstall the app and retry.';
    }
    return 'OCR failed: $e';
  }
}
