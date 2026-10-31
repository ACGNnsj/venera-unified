import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/app.dart';

void main() {
  test('a writable directory is used as is', () async {
    final root = await Directory.systemTemp.createTemp('app-writable-path');
    addTearDown(() => root.delete(recursive: true));

    final resolved = await App.writablePathForTesting(root.path);

    expect(resolved, root.path);
    expect(Directory(resolved).existsSync(), isTrue);
  });

  test('an existing directory gains no probe leftovers', () async {
    final root = await Directory.systemTemp.createTemp('app-writable-probe');
    addTearDown(() => root.delete(recursive: true));

    await App.writablePathForTesting(root.path);

    expect(root.listSync().whereType<File>(), isEmpty);
  });
}
