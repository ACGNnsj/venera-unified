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

  test('没有设置 PIN 时不拦截', () async {
    expect(await AuthStorage.hasPassword(), isFalse);
    expect(await AuthStorage.verify('1234'), isTrue);
  });

  test('设置后校验正确与错误的 PIN', () async {
    await AuthStorage.writePassword('1234');
    expect(await AuthStorage.hasPassword(), isTrue);
    expect(await AuthStorage.verify('1234'), isTrue);
    expect(await AuthStorage.verify('4321'), isFalse);
  });

  test('落盘的是摘要而不是明文', () async {
    await AuthStorage.writePassword('1234');
    final raw = await File('${dir.path}/auth.json').readAsString();
    expect(raw.contains('1234'), isFalse);
    expect(raw, contains(AuthStorage.hashPassword('1234')));
  });

  test('清除 PIN 会删掉文件', () async {
    await AuthStorage.writePassword('1234');
    await AuthStorage.writePassword(null);
    expect(await AuthStorage.hasPassword(), isFalse);
    expect(await File('${dir.path}/auth.json').exists(), isFalse);
  });

  test('文件损坏时当作未设置，不把人锁在门外', () async {
    await File('${dir.path}/auth.json').writeAsString('{ not json');
    expect(await AuthStorage.hasPassword(), isFalse);
    expect(await AuthStorage.verify('1234'), isTrue);
  });
}
