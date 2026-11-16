import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_details/comic_page.dart';

void main() {
  test('ComicPage carries optional initialPage, default null', () {
    expect(const ComicPage(id: 'a', sourceKey: 'b').initialPage, isNull);
    expect(
      const ComicPage(id: 'a', sourceKey: 'b', initialPage: 7).initialPage,
      7,
    );
  });
}
