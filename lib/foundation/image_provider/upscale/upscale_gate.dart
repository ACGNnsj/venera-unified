import 'dart:typed_data';

import 'package:venera_unified/foundation/log.dart';

import 'anime4k_v4_service.dart';

/// 阅读/下载链路的 Anime4K v4 超分接线 helper。
///
/// 两处缝共用：[enabled] 为 false 时直接返回原图；模型缺失、非 Android、
/// 原生失败等任何异常都回退原图，超分永远不破坏图片加载/下载。
Future<Uint8List> upscaleIfEnabled(
  Uint8List bytes, {
  required String cacheKey,
  required bool enabled,
}) async {
  if (!enabled) return bytes;
  try {
    return await Anime4KV4Service.instance.processImage(
          imageBytes: bytes,
          cacheKey: cacheKey,
        ) ??
        bytes;
  } catch (e, s) {
    Log.error('Anime4KV4', 'upscale wiring fallback: $e', s);
    return bytes;
  }
}
