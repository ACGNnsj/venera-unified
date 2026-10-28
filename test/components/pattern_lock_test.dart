import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/components/pattern_lock.dart';

void main() {
  test('patternToString 序列化稳定', () {
    expect(patternToString([0, 1, 4, 8]), '0-1-4-8');
    expect(patternToString([5]), '5');
    expect(patternToString([]), '');
  });
}
