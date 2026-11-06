import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final translations = Map<String, dynamic>.from(
    jsonDecode(File('assets/translation.json').readAsStringSync()),
  );

  test('all literal translation keys used by Dart code are defined', () {
    // A literal may be split from its .tl suffix across lines (the formatter
    // does that for long strings), so the gap between the closing quote and
    // the suffix is whitespace, not nothing. Triple-quoted strings are
    // removed first because they would otherwise capture a quote pair.
    final literalPattern = RegExp(
      r'''(["'])((?:(?!\1)[^\\]|\\.)*)\1\s*\.(?:tl|tlParams)\b''',
    );
    final tripleQuoted = RegExp(r'''\'\'\'[\s\S]*?\'\'\'|"""[:\s\S]*?"""''');
    final keys = <String>{};
    final sourceFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in sourceFiles) {
      final source = file.readAsStringSync().replaceAll(tripleQuoted, "''");
      for (final match in literalPattern.allMatches(source)) {
        keys.add(match.group(2)!);
      }
    }

    final localeMaps = {
      for (final entry in translations.entries)
        entry.key: Map<String, dynamic>.from(entry.value as Map),
    };
    for (final entry in localeMaps.entries) {
      final missing = <String>[];
      for (final key in keys) {
        if (!entry.value.containsKey(key)) {
          missing.add(key);
        }
      }
      missing.sort();
      expect(
        missing,
        isEmpty,
        reason: '${entry.key} is missing translations:\n${missing.join('\n')}',
      );
    }
  });

  test('translation keys are language-neutral', () {
    final cjk = RegExp(r'[\u4e00-\u9fff]');
    final keys = Map<String, dynamic>.from(translations.values.first as Map);
    for (final key in keys.keys) {
      expect(
        cjk.hasMatch(key),
        isFalse,
        reason: 'invalid translation key: $key',
      );
    }
  });
}
