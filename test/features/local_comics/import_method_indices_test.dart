import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/local_comics/local_comics_summary.dart';

void main() {
  test('HarmonyOS hides the PDF entry without renumbering the others', () {
    expect(importMethodIndices(8, isOhos: true), [0, 1, 2, 3, 5, 6, 7]);
  });

  test('other platforms offer every import method in dialog order', () {
    expect(importMethodIndices(8, isOhos: false), [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('the offered indices stop at the supplied method count', () {
    expect(importMethodIndices(5, isOhos: true), [0, 1, 2, 3]);
    expect(importMethodIndices(5, isOhos: false), [0, 1, 2, 3, 4]);
  });
}
