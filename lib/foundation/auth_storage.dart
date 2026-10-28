import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:venera_unified/foundation/app.dart';

/// Available unlock methods for the app lock (ported from VeneraX).
///
/// [biometric] delegates to the device's fingerprint/face hardware and needs
/// no stored secret. The remaining three are self-contained fallbacks that
/// work on devices without biometric hardware.
enum AppLockType {
  biometric,
  pin,
  password,
  pattern;

  static AppLockType fromName(String? name) {
    return AppLockType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => AppLockType.biometric,
    );
  }
}

/// 应用内解锁凭据的存储与校验。
///
/// 文件是 `<应用数据目录>/auth.json`，与 `appdata` 同目录，但独立于设置库：
/// 设置回滚、导入导出都不该把凭据带出去。
///
/// 新格式只存加盐 SHA-256 摘要，明文口令不落盘：
/// `{'type': 'pin', 'salt': ..., 'hash': sha256('salt::secret')}`（盐与拼接
/// 方式照抄 VeneraX `AppLock`）。旧格式 `{'password': 无盐摘要}` 仍可校验，
/// 成功时自动升级为加盐格式。
class AuthStorage {
  /// 测试用：把存储目录指到临时目录，避免依赖 bootstrap 设置的 [App.dataPath]。
  @visibleForTesting
  static Directory? debugDirectory;

  static File get _file => File(
    '${(debugDirectory?.path ?? App.dataPath)}${Platform.pathSeparator}auth.json',
  );

  static Future<Map<String, dynamic>?> _readFile() async {
    final file = _file;
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      // 文件被截断或手工改坏时当作没设置，避免把用户永久锁在门外。
      return json is Map<String, dynamic> ? json : null;
    } catch (_) {
      return null;
    }
  }

  /// 已设置的凭据类型；没有设置时返回 null。
  ///
  /// 旧无盐格式没有类型字段，一律视为 [AppLockType.pin]（当时只有 PIN）。
  static Future<AppLockType?> credentialType() async {
    final json = await _readFile();
    if (json == null) return null;
    if (_isLegacy(json)) return AppLockType.pin;
    final hash = json['hash'];
    if (hash is! String || hash.isEmpty) return null;
    final type = AppLockType.fromName(json['type'] as String?);
    // 新格式里 biometric 不该带 hash；真遇上这种不一致也按 pin 给出解锁 UI，
    // 校验本身不看类型，不会把人锁在门外。
    return type == AppLockType.biometric ? AppLockType.pin : type;
  }

  static Future<bool> hasPassword() async => (await credentialType()) != null;

  /// 设置凭据（加盐存储）。传 [AppLockType.biometric] 表示清除（生物识别
  /// 不需要存任何东西）。
  static Future<void> writeCredential(
    AppLockType type, [
    String? secret,
  ]) async {
    final file = _file;
    if (type == AppLockType.biometric || secret == null || secret.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    final salt = _newSalt();
    final data = jsonEncode({
      'type': type.name,
      'salt': salt,
      'hash': _saltedHash(secret, salt),
    });
    await file.writeAsString(data, flush: true);
  }

  /// 校验输入是否与已设置的凭据一致；没有设置时返回 true（不拦截）。
  ///
  /// 旧无盐凭据校验成功时自动升级为加盐格式；升级写盘失败不影响本次放行。
  static Future<bool> verify(String secret) async {
    final json = await _readFile();
    if (json == null) return true;
    if (_isLegacy(json)) {
      if (json['password'] != hashPassword(secret)) return false;
      try {
        await writeCredential(AppLockType.pin, secret);
      } catch (_) {
        // 升级只是顺手优化，失败也不该把刚验对的用户拦下。
      }
      return true;
    }
    final salt = json['salt'];
    final hash = json['hash'];
    if (salt is! String || hash is! String) return true;
    return _saltedHash(secret, salt) == hash;
  }

  /// 旧无盐摘要：只剩兼容老文件一个用途，新凭据一律走加盐。
  static String hashPassword(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  static String _saltedHash(String secret, String salt) =>
      sha256.convert(utf8.encode('$salt::$secret')).toString();

  static String _newSalt() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  static bool _isLegacy(Map<String, dynamic> json) {
    final password = json['password'];
    return password is String && password.isNotEmpty;
  }
}
