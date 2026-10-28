import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/auth_storage.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('auth_storage_test');
    AuthStorage.debugDirectory = dir;
  });

  tearDown(() async {
    AuthStorage.debugDirectory = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<Map<String, dynamic>> readRaw() async {
    final raw = await File('${dir.path}/auth.json').readAsString();
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  test('没有设置 PIN 时不拦截', () async {
    expect(await AuthStorage.hasPassword(), isFalse);
    expect(await AuthStorage.credentialType(), isNull);
    expect(await AuthStorage.verify('1234'), isTrue);
  });

  test('新凭据加盐存储并校验', () async {
    await AuthStorage.writeCredential(AppLockType.pin, '1234');
    expect(await AuthStorage.hasPassword(), isTrue);
    expect(await AuthStorage.credentialType(), AppLockType.pin);
    expect(await AuthStorage.verify('1234'), isTrue);
    expect(await AuthStorage.verify('4321'), isFalse);
  });

  test('落盘的是加盐摘要而不是明文', () async {
    await AuthStorage.writeCredential(AppLockType.pin, '1234');
    final raw = await File('${dir.path}/auth.json').readAsString();
    expect(raw.contains('1234'), isFalse);
    // 无盐摘要也不该出现：新格式只认加盐。
    expect(raw.contains(AuthStorage.hashPassword('1234')), isFalse);
    final json = await readRaw();
    expect(json['type'], 'pin');
    expect(json['salt'], isA<String>());
    expect((json['salt'] as String).isNotEmpty, isTrue);
    expect(json['hash'], isA<String>());
  });

  test('两次写入盐不同', () async {
    await AuthStorage.writeCredential(AppLockType.pin, '1234');
    final first = (await readRaw())['salt'];
    await AuthStorage.writeCredential(AppLockType.pin, '1234');
    final second = (await readRaw())['salt'];
    expect(first, isNot(equals(second)));
    expect(await AuthStorage.verify('1234'), isTrue);
  });

  test('旧无盐文件兼容：验对后自动升级为加盐格式', () async {
    await File(
      '${dir.path}/auth.json',
    ).writeAsString(jsonEncode({'password': AuthStorage.hashPassword('1234')}));
    expect(await AuthStorage.credentialType(), AppLockType.pin);
    expect(await AuthStorage.verify('1234'), isTrue);
    final json = await readRaw();
    expect(json.containsKey('password'), isFalse);
    expect(json['type'], 'pin');
    expect(json['salt'], isA<String>());
    // 升级后照常用。
    expect(await AuthStorage.verify('1234'), isTrue);
    expect(await AuthStorage.verify('4321'), isFalse);
  });

  test('旧无盐文件密码错误时不升级', () async {
    await File(
      '${dir.path}/auth.json',
    ).writeAsString(jsonEncode({'password': AuthStorage.hashPassword('1234')}));
    expect(await AuthStorage.verify('4321'), isFalse);
    final json = await readRaw();
    expect(json['password'], AuthStorage.hashPassword('1234'));
    expect(json.containsKey('salt'), isFalse);
  });

  test('password 与 pattern 类型 round-trip', () async {
    await AuthStorage.writeCredential(AppLockType.password, 's3cret!');
    expect(await AuthStorage.credentialType(), AppLockType.password);
    expect(await AuthStorage.verify('s3cret!'), isTrue);
    expect(await AuthStorage.verify('S3CRET!'), isFalse);

    await AuthStorage.writeCredential(AppLockType.pattern, '0-1-4-8');
    expect(await AuthStorage.credentialType(), AppLockType.pattern);
    expect(await AuthStorage.verify('0-1-4-8'), isTrue);
    expect(await AuthStorage.verify('0-1-4-7'), isFalse);
  });

  test('清除凭据会删掉文件', () async {
    await AuthStorage.writeCredential(AppLockType.pin, '1234');
    await AuthStorage.writeCredential(AppLockType.biometric);
    expect(await AuthStorage.hasPassword(), isFalse);
    expect(await AuthStorage.credentialType(), isNull);
    expect(await File('${dir.path}/auth.json').exists(), isFalse);
  });

  test('文件损坏时当作未设置，不把人锁在门外', () async {
    await File('${dir.path}/auth.json').writeAsString('{ not json');
    expect(await AuthStorage.hasPassword(), isFalse);
    expect(await AuthStorage.verify('1234'), isTrue);
  });

  test('fromName 未知回退 biometric', () {
    expect(AppLockType.fromName('pattern'), AppLockType.pattern);
    expect(AppLockType.fromName('nope'), AppLockType.biometric);
    expect(AppLockType.fromName(null), AppLockType.biometric);
  });
}
