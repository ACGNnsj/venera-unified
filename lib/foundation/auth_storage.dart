import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:venera_unified/foundation/app.dart';

/// 应用内 PIN 的存储与校验。
///
/// 文件是 `<应用数据目录>/auth.json`，与 `appdata` 同目录，但独立于设置库：
/// 设置回滚、导入导出都不该把凭据带出去。
///
/// 只存 SHA-256 摘要，明文口令不落盘。
class AuthStorage {
  /// 测试用：把存储目录指到临时目录，避免依赖 bootstrap 设置的 [App.dataPath]。
  @visibleForTesting
  static Directory? debugDirectory;

  static File get _file => File(
    '${(debugDirectory?.path ?? App.dataPath)}${Platform.pathSeparator}auth.json',
  );

  /// 已设置的 PIN 摘要；没有设置时返回 null。
  static Future<String?> readPasswordHash() async {
    final file = _file;
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      final password = json['password'];
      return password is String && password.isNotEmpty ? password : null;
    } catch (_) {
      // 文件被截断或手工改坏时当作没设置，避免把用户永久锁在门外。
      return null;
    }
  }

  static Future<bool> hasPassword() async => (await readPasswordHash()) != null;

  /// 设置或清除 PIN。传 null 表示清除。
  static Future<void> writePassword(String? password) async {
    final file = _file;
    if (password == null || password.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    final data = jsonEncode({'password': hashPassword(password)});
    await file.writeAsString(data, flush: true);
  }

  /// 校验输入是否与已设置的 PIN 一致；没有设置时返回 true（不拦截）。
  static Future<bool> verify(String password) async {
    final stored = await readPasswordHash();
    if (stored == null) return true;
    return stored == hashPassword(password);
  }

  static String hashPassword(String password) =>
      sha256.convert(utf8.encode(password)).toString();
}
