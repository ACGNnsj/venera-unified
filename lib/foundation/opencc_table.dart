/// Immutable Chinese conversion: phrase-level longest-match first, then a
/// character-level fallback from the bundled two-column table.
///
/// Duplicate keys retain the last mapping, matching the existing table order.
class OpenCCTable {
  OpenCCTable._(
    Map<int, int> simplified,
    Map<int, int> traditional,
    Map<String, String> simplifiedPhrases,
    Map<String, String> traditionalPhrases,
  ) : _simplified = Map.unmodifiable(simplified),
      _traditional = Map.unmodifiable(traditional),
      _simplifiedPhrases = Map.unmodifiable(simplifiedPhrases),
      _traditionalPhrases = Map.unmodifiable(traditionalPhrases),
      _simplifiedPhraseLen = _longestKey(simplifiedPhrases),
      _traditionalPhraseLen = _longestKey(traditionalPhrases);

  factory OpenCCTable.parse(
    String text, {
    Map<int, int> simplifiedCharacters = const {},
    Map<int, int> traditionalCharacters = const {},
    Map<String, String> simplifiedPhrases = const {},
    Map<String, String> traditionalPhrases = const {},
  }) {
    final simplified = <int, int>{};
    final traditional = <int, int>{};
    for (final raw in text.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty || line.startsWith('#')) continue;
      final runes = line.runes.toList();
      if (runes.length != 2) continue;
      simplified[runes[0]] = runes[1];
      traditional[runes[1]] = runes[0];
    }
    // 内置表比 OpenCC 原表小，缺的字用原表补齐（已有的映射优先保留）。
    simplifiedCharacters.forEach((from, to) {
      simplified.putIfAbsent(from, () => to);
    });
    traditionalCharacters.forEach((from, to) {
      traditional.putIfAbsent(from, () => to);
    });
    return OpenCCTable._(
      simplified,
      traditional,
      simplifiedPhrases,
      traditionalPhrases,
    );
  }

  /// Parses an OpenCC character dictionary (`key\tvalue(s)` per line).
  ///
  /// Only single-character keys are kept; space-separated alternatives keep
  /// the first one.
  static Map<int, int> parseCharacters(String text) {
    final characters = <int, int>{};
    for (final raw in text.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty || line.startsWith('#')) continue;
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final keyRunes = line.substring(0, tab).runes.toList();
      if (keyRunes.length != 1) continue;
      var value = line.substring(tab + 1);
      final space = value.indexOf(' ');
      if (space >= 0) value = value.substring(0, space);
      final valueRunes = value.runes.toList();
      if (valueRunes.length != 1) continue;
      characters[keyRunes.single] = valueRunes.single;
    }
    return characters;
  }

  /// Parses an OpenCC phrase dictionary (`key\tvalue` per line).
  ///
  /// The value may list space-separated alternatives; the first one wins.
  /// Lines that are empty, commented, or lack a tab are skipped.
  static Map<String, String> parsePhrases(String text) {
    final phrases = <String, String>{};
    for (final raw in text.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty || line.startsWith('#')) continue;
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final key = line.substring(0, tab);
      var value = line.substring(tab + 1);
      final space = value.indexOf(' ');
      if (space >= 0) value = value.substring(0, space);
      if (value.isEmpty) continue;
      phrases[key] = value;
    }
    return phrases;
  }

  /// 词表里最长的键长，用来限制 FMM 的回溯深度；超过 [maxPhraseLength]
  /// 的条目很少见且命中率极低，裁掉可以避免长文本上的无谓开销。
  static const int maxPhraseLength = 8;

  final Map<int, int> _simplified;
  final Map<int, int> _traditional;
  final Map<String, String> _simplifiedPhrases;
  final Map<String, String> _traditionalPhrases;
  final int _simplifiedPhraseLen;
  final int _traditionalPhraseLen;

  bool get hasPhrases => _simplifiedPhrases.isNotEmpty;

  bool hasSimplified(String text) => text.runes.any(_simplified.containsKey);

  bool hasTraditional(String text) => text.runes.any(_traditional.containsKey);

  String toTraditional(String text) =>
      _convert(text, _simplified, _simplifiedPhrases, _simplifiedPhraseLen);

  String toSimplified(String text) =>
      _convert(text, _traditional, _traditionalPhrases, _traditionalPhraseLen);

  static int _longestKey(Map<String, String> phrases) {
    var longest = 0;
    for (final key in phrases.keys) {
      final length = key.runes.length;
      if (length > longest) longest = length;
    }
    return longest > maxPhraseLength ? maxPhraseLength : longest;
  }

  /// Forward maximum matching against [phrases], falling back to the
  /// character table for everything that does not match a phrase.
  ///
  /// Phrases win over characters so that polysemes convert correctly
  /// (e.g. 头发 -> 頭髮 rather than 頭發).
  static String _convert(
    String text,
    Map<int, int> chars,
    Map<String, String> phrases,
    int phraseLength,
  ) {
    if (phrases.isEmpty || phraseLength < 2) {
      return String.fromCharCodes(
        text.runes.map((rune) => chars[rune] ?? rune),
      );
    }
    final runes = text.runes.toList();
    final buffer = StringBuffer();
    var index = 0;
    while (index < runes.length) {
      var matched = false;
      final limit = runes.length - index;
      final longest = limit < phraseLength ? limit : phraseLength;
      for (var length = longest; length >= 2; length--) {
        final candidate = String.fromCharCodes(runes, index, index + length);
        final converted = phrases[candidate];
        if (converted != null) {
          buffer.write(converted);
          index += length;
          matched = true;
          break;
        }
      }
      if (matched) continue;
      final rune = runes[index];
      buffer.writeCharCode(chars[rune] ?? rune);
      index++;
    }
    return buffer.toString();
  }
}
