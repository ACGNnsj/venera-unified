// Ported from Venera-SSR lib/utils/anime4k/anime4k_v4_model_manager.dart.
// Phase 1 trim: single bundled model (official ACNet 2x), asset extraction +
// path resolution only. Dropped: downloader, mirror URLs, custom model import,
// SharedPreferences state. No persistence needed: with one bundled model,
// extraction is idempotent (extract-if-missing).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:venera_unified/foundation/log.dart';

///单个 v4 超分模型的定义。
///
/// [scale] 仅作 UI 提示；真正的放大倍数与输入通道数（3=RGB / 1=Y）由原生
/// [UpscaleEngine.getModelInfo] 从模型实际输入/输出维度探测，因此换权重
/// 无需改原生代码。
class V4ModelDef {
  final String id;
  final String fileName;
  final String displayName;
  final int scale;

  /// 模型输入通道数：1 = Y 亮度（官方 ACNet，强制 CPU），
  /// 3 = RGB（Real-ESRGAN，NNAPI 优先、失败回退 CPU）。
  final int channels;
  final String? bundledAssetPath;

  const V4ModelDef({
    required this.id,
    required this.fileName,
    required this.displayName,
    required this.scale,
    required this.channels,
    this.bundledAssetPath,
  });
}

/// v4 超分模型管理器：管理 Anime4K v4 超分 ONNX 模型（第一阶段仅官方 ACNet 2×）
/// 的生命周期。模型调用位置为 [getApplicationSupportDirectory]/`<fileName>`，
/// 原生经 createSession(modelPath) 直接读取。
class Anime4KV4ModelManager {
  /// 模型注册表，第一阶段仅内置 ACNet。新增权重只需在此追加一项。
  static final List<V4ModelDef> models = [
    const V4ModelDef(
      id: 'anime4k_acnet',
      fileName: 'anime4k_acnet.onnx',
      displayName: 'Anime4K v4 ACNet (2×)',
      scale: 2,
      channels: 1,
      // ACNet 官方 onnx 仅 ~21KB：直接打包进 APK，开箱即用。
      bundledAssetPath: 'assets/models/anime4k_acnet.onnx',
    ),
  ];

  /// 有效模型最小体积（8KB）。ACNet onnx 仅 ~21KB；
  /// 下限用于拦掉损坏/空文件。
  static const int _validModelMinSize = 8 * 1024;

  /// 有效模型的最小体积（字节），供 UI 侧做体积校验。
  static int get validModelMinSize => _validModelMinSize;

  static V4ModelDef _modelById(String id) =>
      models.firstWhere((m) => m.id == id, orElse: () => models.first);

  /// 当前选中模型的定义（第一阶段恒为 ACNet）。
  static V4ModelDef get selectedDef => models.first;

  /// 当前选中模型的文件名（调用位置文件名）。
  static String get modelFileName => selectedDef.fileName;

  /// 全部可用模型（供 UI 构建选择器）。
  static List<V4ModelDef> getModels() => List.unmodifiable(models);

  static bool isValidModelId(String id) => models.any((m) => m.id == id);

  static V4ModelDef modelById(String id) => _modelById(id);

  static String? _cachedModelPath;

  /// 把打包进 APK 的模型（assets）抽取到应用目录（模型调用位置），仅在需要时执行。
  ///
  /// 模型调用位置已有有效文件时直接复用；assets 缺失时静默跳过，
  /// 保证 APK 始终可构建。
  static Future<void> extractBundledModelIfNeeded() async {
    try {
      final def = selectedDef;
      final dir = await getApplicationSupportDirectory();
      final targetPath = path.join(dir.path, def.fileName);
      final targetFile = File(targetPath);

      // 已有有效模型则无需抽取。
      if (await targetFile.exists() &&
          await targetFile.length() > _validModelMinSize) {
        _cachedModelPath = targetPath;
        return;
      }

      final assetPath = def.bundledAssetPath;
      if (assetPath == null) return;

      // 从 assets 读取打包模型；不存在（未打包）则静默跳过。
      final ByteData data;
      try {
        data = await rootBundle.load(assetPath);
      } catch (_) {
        return;
      }

      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (bytes.length <= _validModelMinSize) {
        // 打包文件异常（过小），不写入。
        return;
      }

      // 原子写入：先写临时文件再重命名，避免中断产生半截文件。
      final tmpPath = '$targetPath.bundle.tmp';
      final tmpFile = File(tmpPath);
      await tmpFile.writeAsBytes(bytes, flush: true);
      await tmpFile.rename(targetPath);

      _cachedModelPath = targetPath;
      Log.info(
        'Anime4KV4',
        'bundled model (${def.id}) extracted to $targetPath (${bytes.length} bytes)',
      );
    } catch (e, s) {
      Log.error('Anime4KV4', 'extractBundledModelIfNeeded failed: $e\n$s');
    }
  }

  /// 获取模型文件路径（即模型调用位置）。不自动下载；文件不存在或无效则返回 null。
  static Future<String?> ensureModelAvailable() async {
    final def = selectedDef;
    if (_cachedModelPath != null) {
      final f = File(_cachedModelPath!);
      if (await f.exists() && await f.length() > _validModelMinSize) {
        return _cachedModelPath!;
      }
      _cachedModelPath = null;
    }

    final dir = await getApplicationSupportDirectory();
    final targetPath = path.join(dir.path, def.fileName);
    final targetFile = File(targetPath);

    if (await targetFile.exists()) {
      final size = await targetFile.length();
      if (size > _validModelMinSize) {
        _cachedModelPath = targetPath;
        return targetPath;
      }
      await targetFile.delete();
    }

    return null;
  }

  /// 模型是否已就绪且完整。
  static Future<bool> get isModelDownloaded async {
    final def = selectedDef;
    final dir = await getApplicationSupportDirectory();
    final targetPath = path.join(dir.path, def.fileName);
    final targetFile = File(targetPath);
    if (await targetFile.exists()) {
      final size = await targetFile.length();
      if (size > _validModelMinSize) return true;
    }
    if (_cachedModelPath != null) return true;
    return false;
  }

  static Future<int> getDownloadedSize() async {
    final def = selectedDef;
    final dir = await getApplicationSupportDirectory();
    final targetPath = path.join(dir.path, def.fileName);
    final targetFile = File(targetPath);
    if (!await targetFile.exists()) return 0;
    return await targetFile.length();
  }
}
