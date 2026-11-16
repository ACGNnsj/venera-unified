import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/local_comics/import_export/comic_import_service.dart';

void main() {
  test('unknown mtime falls back to now', () {
    final before = DateTime.now().subtract(const Duration(seconds: 5));
    final result = validLocalModifiedTime(
      DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect(result.isAfter(before), isTrue);
    expect(
      result.isBefore(DateTime.now().add(const Duration(seconds: 5))),
      isTrue,
    );
  });

  test('known mtime passes through', () {
    final known = DateTime(2024, 5, 6, 7, 8, 9);
    expect(validLocalModifiedTime(known), known);
  });
}
