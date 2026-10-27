import 'dart:convert';
import 'package:flutter/services.dart';
import 'opencc_table.dart';

abstract class OpenCC {
  static OpenCCTable? _table;
  static Future<void>? _initialization;

  /// Concurrent calls share one load. Failed loads can be retried; successful
  /// tables remain immutable and are reused for the application lifetime.
  static Future<void> init({AssetBundle? bundle}) =>
      _initialization ??= _load(bundle ?? rootBundle).then(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _initialization = null;
          Error.throwWithStackTrace(error, stack);
        },
      );

  static Future<void> _load(AssetBundle bundle) async {
    final loaded = await Future.wait([
      _loadText(bundle, 'assets/opencc.txt'),
      _loadText(bundle, 'assets/opencc/STCharacters.txt'),
      _loadText(bundle, 'assets/opencc/TSCharacters.txt'),
      _loadText(bundle, 'assets/opencc/STPhrases.txt'),
      _loadText(bundle, 'assets/opencc/TSPhrases.txt'),
    ], eagerError: true);
    final table = OpenCCTable.parse(
      loaded[0],
      simplifiedCharacters: OpenCCTable.parseCharacters(loaded[1]),
      traditionalCharacters: OpenCCTable.parseCharacters(loaded[2]),
      simplifiedPhrases: OpenCCTable.parsePhrases(loaded[3]),
      traditionalPhrases: OpenCCTable.parsePhrases(loaded[4]),
    );
    _table = table;
  }

  static Future<String> _loadText(AssetBundle bundle, String key) async {
    final data = await bundle.load(key);
    return utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  static OpenCCTable get _ready =>
      _table ?? (throw StateError('OpenCC is not initialized'));

  static bool hasChineseSimplified(String text) => _ready.hasSimplified(text);
  static bool hasChineseTraditional(String text) => _ready.hasTraditional(text);
  static String simplifiedToTraditional(String text) =>
      _ready.toTraditional(text);
  static String traditionalToSimplified(String text) =>
      _ready.toSimplified(text);
}
