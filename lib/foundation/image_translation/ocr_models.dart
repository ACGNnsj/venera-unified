import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../app.dart';

/// Pinned ModelScope commit serving the PP-OCRv4 files. The revision is locked
/// in every asset URL; the size + sha256 pins below are verified after
/// download, so a silent upstream swap fails loudly instead of misbehaving.
const String kOcrModelRevision = '7d0781614ca1a83d5ad9603f713acb2e74855d72';

/// One OCR asset: exact URL, byte size and content hash, all pinned.
class OcrModelAsset {
  const OcrModelAsset({
    required this.name,
    required this.fileName,
    required this.url,
    required this.bytes,
    required this.sha256,
  });

  /// Short display name used in progress and error messages.
  final String name;
  final String fileName;
  final String url;
  final int bytes;
  final String sha256;
}

/// The three Japanese OCR assets (PP-OCRv4 det + japan rec + dict).
/// First-use download ≈ 14.5 MB. Verified against ModelScope 2026-10-29.
List<OcrModelAsset> ocrModelAssets() => [
  OcrModelAsset(
    name: 'Text detector',
    fileName: 'ch_PP-OCRv4_det_mobile.onnx',
    url:
        'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/master/'
        'onnx/PP-OCRv4/det/ch_PP-OCRv4_det_mobile.onnx'
        '?revision=$kOcrModelRevision',
    bytes: 4745517,
    sha256: 'd2a7720d45a54257208b1e13e36a8479894cb74155a5efe29462512d42f49da9',
  ),
  OcrModelAsset(
    name: 'Japanese recognizer',
    fileName: 'japan_PP-OCRv4_rec_mobile.onnx',
    url:
        'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/master/'
        'onnx/PP-OCRv4/rec/japan_PP-OCRv4_rec_mobile.onnx'
        '?revision=$kOcrModelRevision',
    bytes: 9753335,
    sha256: 'e1075a67dba758ecfc7ebc78a10ae61c95ac8fb66a9c86fab5541e33f085cb7a',
  ),
  OcrModelAsset(
    name: 'Japanese dictionary',
    fileName: 'japan_dict.txt',
    url:
        'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/master/'
        'paddle/PP-OCRv4/rec/japan_PP-OCRv4_rec_mobile/japan_dict.txt'
        '?revision=$kOcrModelRevision',
    bytes: 17332,
    sha256: '1dcfcb41eec90576a945b3084f22ade11ced506e24f14879245b071698f308e8',
  ),
];

/// Total first-use download size across all assets.
int ocrModelsTotalBytes() =>
    ocrModelAssets().fold(0, (sum, asset) => sum + asset.bytes);

/// Local paths of verified model files, handed to the OCR worker.
class OcrModelPaths {
  OcrModelPaths({
    required this.detector,
    required this.recModel,
    required this.recDict,
  });

  final String detector;
  final String recModel;
  final String recDict;
}

/// Readable model-download failure. Never silent: the message names the asset
/// and says what to do (retry), and the caller surfaces a retry entry.
class OcrModelException implements Exception {
  OcrModelException(this.message);

  final String message;

  @override
  String toString() => 'OcrModelException: $message';
}

/// Ensures the three OCR assets exist under the app data dir and match their
/// pins, downloading any missing or broken file.
///
/// [onProgress] reports (assetIndex, assetCount, receivedBytes, totalBytes)
/// across the whole set. Files already present and valid are skipped without
/// any download. A file that fails size/hash verification is deleted so the
/// next call re-downloads it cleanly.
Future<OcrModelPaths> ensureOcrModels({
  void Function(int index, int count, int received, int total)? onProgress,
}) async {
  var assets = ocrModelAssets();
  var dir = Directory(p.join(App.dataPath, 'ocr_models'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  var total = ocrModelsTotalBytes();
  var received = 0;
  var dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
  try {
    for (var i = 0; i < assets.length; i++) {
      var asset = assets[i];
      var file = File(p.join(dir.path, asset.fileName));
      if (await _isValid(file, asset)) {
        received += asset.bytes;
        onProgress?.call(i + 1, assets.length, received, total);
        continue;
      }
      if (await file.exists()) {
        await file.delete();
      }
      try {
        await dio.download(
          asset.url,
          file.path,
          options: Options(
            receiveTimeout: const Duration(minutes: 10),
            // ModelScope answers 200 only; anything else is an error page.
            validateStatus: (status) => status == 200,
          ),
          onReceiveProgress: (count, _) {
            onProgress?.call(i + 1, assets.length, received + count, total);
          },
        );
        received += await file.length();
        onProgress?.call(i + 1, assets.length, received, total);
      } on DioException catch (e) {
        if (await file.exists()) {
          await file.delete();
        }
        throw OcrModelException(
          'Could not download ${asset.name} (${_shortError(e)}). '
          'Check the network connection and retry.',
        );
      }
      if (!await _isValid(file, asset)) {
        if (await file.exists()) {
          await file.delete();
        }
        throw OcrModelException(
          '${asset.name} failed verification (size or content mismatch, '
          'expected ${asset.bytes} bytes). Delete any partial file and retry.',
        );
      }
    }
  } finally {
    dio.close();
  }
  return OcrModelPaths(
    detector: p.join(dir.path, assets[0].fileName),
    recModel: p.join(dir.path, assets[1].fileName),
    recDict: p.join(dir.path, assets[2].fileName),
  );
}

Future<bool> _isValid(File file, OcrModelAsset asset) async {
  if (!await file.exists()) return false;
  if (await file.length() != asset.bytes) return false;
  var digest = await sha256.bind(file.openRead()).first;
  return digest.toString() == asset.sha256;
}

String _shortError(DioException e) {
  var status = e.response?.statusCode;
  if (status != null) return 'HTTP $status';
  return switch (e.type) {
    DioExceptionType.connectionTimeout => 'connection timed out',
    DioExceptionType.receiveTimeout => 'download timed out',
    DioExceptionType.connectionError => 'connection failed',
    _ => 'network error',
  };
}
