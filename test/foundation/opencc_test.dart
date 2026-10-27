import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/opencc.dart';
import 'package:venera_unified/foundation/opencc_table.dart';

class _Bundle extends CachingAssetBundle {
  final requests = <Completer<ByteData>>[];
  @override
  Future<ByteData> load(String key) {
    final request = Completer<ByteData>();
    requests.add(request);
    return request.future;
  }
}

ByteData _bytesOf(String text) {
  final list = utf8.encode(text);
  return ByteData.view(Uint8List.fromList(list).buffer);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'load failure is shared, retry publishes atomically and success is reused',
    () async {
      final bundle = _Bundle();
      expect(() => OpenCC.hasChineseSimplified('汉'), throwsStateError);
      final first = OpenCC.init(bundle: bundle);
      expect(OpenCC.init(bundle: bundle), same(first));
      final failure = expectLater(first, throwsStateError);
      expect(bundle.requests, hasLength(5));
      bundle.requests.first.completeError(StateError('asset unavailable'));
      await failure;
      expect(() => OpenCC.hasChineseTraditional('漢'), throwsStateError);
      final retry = OpenCC.init(bundle: bundle);
      expect(bundle.requests, hasLength(10));
      bundle.requests[5].complete(_bytesOf('汉漢\n马馬'));
      bundle.requests[6].complete(_bytesOf(''));
      bundle.requests[7].complete(_bytesOf('髮\t发'));
      bundle.requests[8].complete(_bytesOf('头发\t頭髮'));
      bundle.requests[9].complete(_bytesOf('頭髮\t头发'));
      await retry;
      expect(OpenCC.init(bundle: bundle), same(retry));
      expect(OpenCC.hasChineseSimplified('汉字'), isTrue);
      expect(OpenCC.hasChineseTraditional('漢字'), isTrue);
      expect(OpenCC.simplifiedToTraditional('汉马🙂'), '漢馬🙂');
      expect(OpenCC.traditionalToSimplified('漢馬🙂'), '汉马🙂');
      expect(OpenCC.simplifiedToTraditional('头发'), '頭髮');
      expect(OpenCC.traditionalToSimplified('頭髮'), '头发');
      expect(bundle.requests, hasLength(10));
    },
  );

  test('table handles CRLF, supplementary characters and invalid rows', () {
    final table = OpenCCTable.parse('# comment\r\n汉漢\r\n㓆𠗣\ninvalid\n\n');
    expect(table.toTraditional('汉㓆🙂abc'), '漢𠗣🙂abc');
    expect(table.toSimplified('漢𠗣🙂abc'), '汉㓆🙂abc');
    expect(table.hasSimplified('hello汉'), isTrue);
    expect(table.hasTraditional('𠗣'), isTrue);
    expect(table.hasSimplified('hello🙂'), isFalse);
    expect(table.hasTraditional(''), isFalse);
  });

  test('last duplicate mapping wins in each direction', () {
    final table = OpenCCTable.parse('发發\n发髮\n髪髮');
    expect(table.toTraditional('发'), '髮');
    expect(table.toSimplified('髮'), '髪');
  });

  test('phrase dictionary parsing takes the first alternative', () {
    final phrases = OpenCCTable.parsePhrases(
      '# comment\r\n头发\t頭髮 頭法\r\ninvalid line\r\n\t空键\r\n',
    );
    expect(phrases, {'头发': '頭髮'});
  });

  test('phrases match before characters and longest match wins', () {
    final table = OpenCCTable.parse(
      '发發\n',
      simplifiedPhrases: {'头发': '頭髮', '发廊': '髮廊'},
    );
    expect(table.toTraditional('头发发'), '頭髮發');
    expect(table.toTraditional('发廊发'), '髮廊發');
    // 没有命中词组的位置仍走单字表。
    expect(table.toTraditional('发'), '發');

    final longest = OpenCCTable.parse(
      '件件\n',
      simplifiedPhrases: {'软件': '軟體', '软件源': '軟體源'},
    );
    expect(longest.toTraditional('软件源'), '軟體源');
    expect(longest.toTraditional('软件'), '軟體');
  });

  test(
    'bundled mappings preserve supported BMP conversions and include extensions',
    () async {
      final data = await rootBundle.loadString('assets/opencc.txt');
      final table = OpenCCTable.parse(data);
      expect(table.toTraditional('漫画汉语门马'), '漫畫漢語門馬');
      expect(table.toSimplified('漫畫漢語門馬'), '漫画汉语门马');
      expect(table.hasSimplified('漫画'), isTrue);
      expect(table.hasTraditional('漫畫'), isTrue);
      expect(table.toTraditional('㓆'), '𠗣');
    },
  );

  test('bundled phrase tables are loaded and convert polysemes', () async {
    final chars = await rootBundle.loadString('assets/opencc.txt');
    final stChars = await rootBundle.loadString(
      'assets/opencc/STCharacters.txt',
    );
    final tsChars = await rootBundle.loadString(
      'assets/opencc/TSCharacters.txt',
    );
    final s2t = await rootBundle.loadString('assets/opencc/STPhrases.txt');
    final t2s = await rootBundle.loadString('assets/opencc/TSPhrases.txt');
    final table = OpenCCTable.parse(
      chars,
      simplifiedCharacters: OpenCCTable.parseCharacters(stChars),
      traditionalCharacters: OpenCCTable.parseCharacters(tsChars),
      simplifiedPhrases: OpenCCTable.parsePhrases(s2t),
      traditionalPhrases: OpenCCTable.parsePhrases(t2s),
    );
    expect(table.hasPhrases, isTrue);
    // 「头发」按词组转成「頭髮」，而不是逐字的「頭發」。
    expect(table.toTraditional('头发'), '頭髮');
    expect(table.toSimplified('頭髮'), '头发');
    // 词组表之外的字仍由单字表兜底。
    expect(table.toTraditional('漫画'), '漫畫');
  });
}
