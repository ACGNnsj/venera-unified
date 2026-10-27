import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/text_scale.dart';

void main() {
  test('bounds match the venera slider range', () {
    expect(minTextScale, 0.85);
    expect(maxTextScale, 1.30);
  });

  test('identity user scale keeps the system scale inside the range', () {
    expect(effectiveTextScale(1.0, 1.0), 1.0);
    expect(effectiveTextScale(1.2, 1.0), closeTo(1.2, 1e-9));
  });

  test('composes system and user scales multiplicatively', () {
    expect(effectiveTextScale(1.1, 1.15), closeTo(1.265, 1e-9));
  });

  test('clamps the product to the supported range', () {
    expect(effectiveTextScale(0.5, 0.85), 0.85);
    expect(effectiveTextScale(2.0, 1.30), 1.30);
    expect(effectiveTextScale(1.5, 1.30), 1.30);
  });
}
