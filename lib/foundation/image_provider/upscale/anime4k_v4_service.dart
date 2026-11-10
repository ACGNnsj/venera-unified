// Ported from Venera-SSR lib/utils/anime4k/anime4k_v4_service.dart.
// Changes vs upstream: channel renamed to venera/upscale, method renamed to
// upscale (type arg dropped: native auto-routes by channel count), single
// bundled model (setModel dropped), channels==1 models go straight to CPU.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/log.dart';

import 'acnet_ffi_pipeline.dart';
import 'anime4k_v4_model_manager.dart';
import 'nnapi_devices.dart';

/// Anime4K v4 超分服务（官方 ACNet 2×）。
///
/// 基于 Anime4K v4 超分 ONNX 模型完成超分辨率，倍数由模型实际维度决定。
///  - 单例 + 缓存 + 任务队列；
///  - Android 经 [channelName] MethodChannel 与原生 [UpscaleEngine] 对接
///    （1 通道强制 CPU；3 通道优先 NNAPI，失败回退 CPU）；
///  - 其他平台走 [AcnetFfiPipeline]：同一套分块数学经 ORT FFI 跨平台推理
///    （DirectML / CoreML / XNNPACK / CPU），首 tile 与 CPU 双跑自检。
class Anime4KV4Service {
  Anime4KV4Service._internal();

  static final Anime4KV4Service _instance = Anime4KV4Service._internal();

  factory Anime4KV4Service() => _instance;

  static Anime4KV4Service get instance => _instance;

  /// 与原生端通信的 MethodChannel。
  static const String channelName = 'venera/upscale';

  /// 超分推理方法名。
  static const String upscaleMethod = 'upscale';

  /// 丢弃原生 ONNX 会话方法名。
  static const String resetSessionMethod = 'resetSession';

  static const MethodChannel _channel = MethodChannel(channelName);

  String? _cacheDir;
  String? _modelPath;
  Future<void>? _initFuture;

  /// 原生端 NNAPI 运行时是否可用；未知时按可用处理（原生侧还会再兜一次）。
  bool _nnapiCapable = true;

  bool get nnapiCapable => _nnapiCapable;

  final Set<String> _processingKeys = {};
  static const int _maxConcurrentTasks = 2;
  int _runningTasks = 0;
  final List<Function> _taskQueue = [];

  /// 该通道数的模型是否优先 NNAPI。1 通道（Y 亮度/ACNet）强制 CPU。
  ///
  /// [nnapiAvailable] 来自原生端探测：NNAPI 在 Android 15 起废弃、较新系统已
  /// 移除运行时，此时 3 通道模型也只能走 CPU，否则会多跑一遍注定落回 CPU 的
  /// 参考推理。
  static bool shouldUseNnapi(int channels, {bool nnapiAvailable = true}) =>
      channels != 1 && nnapiAvailable;

  /// 缓存键：前缀含模型 id + intensity，避免串图与旧缓存复用。
  static String buildCacheKey(
    String modelId,
    String cacheKey,
    double intensity,
  ) => 'v4_${modelId}_${cacheKey}_${intensity.toStringAsFixed(2)}';

  /// 初始化缓存目录并探测模型（不自动下载）。
  Future<void> init() async {
    try {
      final dir = await getTemporaryDirectory();
      _cacheDir = path.join(dir.path, 'anime4k_v4_cache');
      final cacheDirectory = Directory(_cacheDir!);
      if (!await cacheDirectory.exists()) {
        await cacheDirectory.create(recursive: true);
      }
      await Anime4KV4ModelManager.extractBundledModelIfNeeded();
      _modelPath = await Anime4KV4ModelManager.ensureModelAvailable();
      if (App.isAndroid) {
        _refreshNnapiCapability();
      }
    } catch (e) {
      Log.error('Anime4KV4', 'init error: $e');
    }
  }

  /// 枚举 NNAPI 设备，判断本机有没有真正的加速器。
  ///
  /// 只看运行库能否加载会误判：Android 17 上库仍在（APEX），却只剩 CPU
  /// 参考实现——NNAPI 会话能建、节点全静默落回 CPU。判据改成「有没有
  /// GPU/NPU 类型的设备」。
  void _refreshNnapiCapability() {
    try {
      final inventory = NnapiDevices.inventory;
      _nnapiCapable = inventory.hasHardwareAccelerator;
      Log.info('Anime4KV4', 'NNAPI ${inventory.describe()}');
    } catch (e) {
      // 探测失败按可用处理，由原生侧与 CPU 参考比对兜底。
      _nnapiCapable = true;
    }
    if (!_nnapiCapable) {
      Log.info('Anime4KV4', 'no NNAPI accelerator, upscale uses CPU only');
    }
  }

  /// 懒初始化：首次超分请求时触发一次即可，调用方无需显式启动钩子。
  /// 可重复调用；并发调用共享同一个在途 init。
  Future<void> ensureInitialized() {
    return _initFuture ??= init();
  }

  /// 模型是否可用（已就绪到本地）。Android 走原生通道，其他平台走 FFI。
  bool get isAvailable => _modelPath != null;

  /// 解析可用模型路径；平台通道不可用（单测/受限环境）时按模型缺失处理。
  Future<String?> _resolveModelPath(String cacheKey) async {
    try {
      if (_modelPath == null) {
        if (!await checkModelAvailable()) {
          Log.warning(
            'Anime4KV4',
            'Model not available, skipping for $cacheKey',
          );
          return null;
        }
      }
      return _modelPath;
    } catch (_) {
      return null;
    }
  }

  Future<bool> checkModelAvailable() async {
    if (_modelPath != null) {
      if (await File(_modelPath!).exists()) return true;
      _modelPath = null;
    }
    _modelPath = await Anime4KV4ModelManager.ensureModelAvailable();
    return _modelPath != null;
  }

  String? _getCachePath(String key) {
    if (_cacheDir == null) return null;
    return path.join(_cacheDir!, '${key.hashCode.abs()}.png');
  }

  Future<Uint8List?> _getFromCache(String key) async {
    final cachePath = _getCachePath(key);
    if (cachePath == null) return null;
    final file = File(cachePath);
    if (await file.exists()) {
      try {
        return await file.readAsBytes();
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  Future<void> _saveToCache(String key, Uint8List data) async {
    final cachePath = _getCachePath(key);
    if (cachePath == null) return;
    try {
      final file = File(cachePath);
      await file.writeAsBytes(data);
    } catch (e) {
      Log.error('Anime4KV4', 'cache save error: $e');
    }
  }

  /// 调用原生端完成超分推理。任何失败返回 null（不抛异常）。
  Future<Uint8List?> _upscaleOnNative(
    Uint8List imageBytes,
    String modelPath,
    double intensity,
    bool useNnapi,
  ) async {
    try {
      final result = await _channel.invokeMethod<Uint8List>(upscaleMethod, {
        'imageBytes': imageBytes,
        'modelPath': modelPath,
        'useNnapi': useNnapi,
        'intensity': intensity,
      });
      return result;
    } catch (e, s) {
      Log.error(
        'Anime4KV4',
        'native upscale failed (useNnapi=$useNnapi): $e\n$s',
      );
      return null;
    }
  }

  /// 丢弃原生端已缓存的 ONNX 会话（模型变更后必须调用）。
  Future<void> resetNativeSession() async {
    try {
      await _channel.invokeMethod<void>(resetSessionMethod);
    } catch (e, s) {
      Log.error('Anime4KV4', 'resetNativeSession failed: $e\n$s');
    }
  }

  /// 处理图片字节数据，返回超分后的 PNG 字节数据（倍数由模型决定）。
  ///
  /// 模型缺失时直接返回 null（上层据此回退或保持原图）。
  Future<Uint8List?> processImage({
    required Uint8List imageBytes,
    required String cacheKey,
    double intensity = 1.0,
  }) async {
    // 首次请求时懒初始化（抽取内置模型 + 建缓存目录），调用方无需启动钩子。
    await ensureInitialized();
    final modelPath = await _resolveModelPath(cacheKey);
    if (modelPath == null) return null;

    final fullKey = buildCacheKey(
      Anime4KV4ModelManager.selectedDef.id,
      cacheKey,
      intensity,
    );

    final cached = await _getFromCache(fullKey);
    if (cached != null) {
      Log.info('Anime4KV4', 'cache hit for $cacheKey');
      return cached;
    }

    if (_processingKeys.contains(fullKey)) {
      Log.info('Anime4KV4', 'already processing $cacheKey');
      return null;
    }

    _processingKeys.add(fullKey);

    return _enqueueTask(() async {
      try {
        Log.info('Anime4KV4', 'processing image $cacheKey');

        Uint8List? result;
        if (!App.isAndroid) {
          // 非 Android：同一套分块数学经 ORT FFI 跨平台推理。
          result = await AcnetFfiPipeline.upscale(
            imageBytes: imageBytes,
            modelPath: modelPath,
            channels: Anime4KV4ModelManager.selectedDef.channels,
            intensity: intensity,
          );
        } else if (shouldUseNnapi(
          Anime4KV4ModelManager.selectedDef.channels,
          nnapiAvailable: _nnapiCapable,
        )) {
          result = await _upscaleOnNative(
            imageBytes,
            modelPath,
            intensity,
            true,
          );
          // NNAPI 失败（不支持/崩溃）时回退纯 CPU 重试一次。
          if (result == null) {
            Log.warning(
              'Anime4KV4',
              'NNAPI failed, retry with CPU for $cacheKey',
            );
            result = await _upscaleOnNative(
              imageBytes,
              modelPath,
              intensity,
              false,
            );
          }
        } else {
          // 1 通道模型强制 CPU，直走 CPU 不试 NNAPI。
          result = await _upscaleOnNative(
            imageBytes,
            modelPath,
            intensity,
            false,
          );
        }

        if (result != null) {
          await _saveToCache(fullKey, result);
          Log.info('Anime4KV4', 'processing complete for $cacheKey');
        }
        return result;
      } catch (e, s) {
        Log.error('Anime4KV4', 'processing error: $e\n$s');
        return null;
      } finally {
        _processingKeys.remove(fullKey);
      }
    });
  }

  Future<T?> _enqueueTask<T>(Future<T?> Function() task) async {
    final completer = Completer<T?>();
    _taskQueue.add(() async {
      _runningTasks++;
      try {
        final result = await task();
        completer.complete(result);
      } catch (e) {
        completer.completeError(e);
      } finally {
        _runningTasks--;
        _nextTask();
      }
    });
    _nextTask();
    return completer.future;
  }

  void _nextTask() {
    if (_runningTasks < _maxConcurrentTasks && _taskQueue.isNotEmpty) {
      final task = _taskQueue.removeAt(0);
      task();
    }
  }

  Future<void> clearCache() async {
    if (_cacheDir == null) return;
    try {
      final dir = Directory(_cacheDir!);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
      }
      Log.info('Anime4KV4', 'cache cleared');
    } catch (e) {
      Log.error('Anime4KV4', 'cache clear error: $e');
    }
  }

  Future<int> getCacheSize() async {
    if (_cacheDir == null) return 0;
    try {
      final dir = Directory(_cacheDir!);
      if (!await dir.exists()) return 0;
      int totalSize = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      return totalSize;
    } catch (e) {
      return 0;
    }
  }
}
