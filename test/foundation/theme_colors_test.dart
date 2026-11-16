import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/theme_colors.dart';

void main() {
  test('all 18 prime presets are registered', () {
    expect(themeColors.keys, containsAll([
      'red',
      'pink',
      'purple',
      'deepPurple',
      'indigo',
      'blue',
      'lightBlue',
      'cyan',
      'teal',
      'green',
      'lightGreen',
      'lime',
      'yellow',
      'amber',
      'orange',
      'deepOrange',
      'brown',
      'blueGrey',
    ]));
    expect(themeColors, hasLength(18));
  });

  test('resolveThemeColor maps presets and falls back to blue', () {
    expect(resolveThemeColor('red', null), Colors.red);
    expect(resolveThemeColor('blueGrey', null), Colors.blueGrey);
    expect(resolveThemeColor('nope', null), Colors.blue);
    expect(resolveThemeColor(null, null), Colors.blue);
  });

  test('resolveThemeColor honors a valid custom ARGB int', () {
    expect(
      resolveThemeColor('custom', 0xFF2196F3),
      const Color(0xFF2196F3),
    );
    // Alpha bits are forced opaque, out-of-range input is rejected.
    expect(
      resolveThemeColor('custom', 0x002196F3).a,
      1.0,
    );
    expect(resolveThemeColor('custom', -1), Colors.blue);
    expect(resolveThemeColor('custom', 0x100000000), Colors.blue);
    expect(resolveThemeColor('custom', 'red'), Colors.blue);
    expect(resolveThemeColor('red', 0xFF2196F3), Colors.red);
  });

  test('parseThemeHex accepts six hex digits with optional #', () {
    expect(parseThemeHex('#2196F3'), const Color(0xFF2196F3));
    expect(parseThemeHex('2196f3'), const Color(0xFF2196F3));
    expect(parseThemeHex('  #FFFFFF  '), const Color(0xFFFFFFFF));
    expect(parseThemeHex(''), isNull);
    expect(parseThemeHex('#12345'), isNull);
    expect(parseThemeHex('#1234567'), isNull);
    expect(parseThemeHex('#ZZZZZZ'), isNull);
    expect(parseThemeHex('red'), isNull);
  });

  test('themeColorHex round-trips through parseThemeHex', () {
    expect(themeColorHex(const Color(0xFF2196F3)), '#2196F3');
    const color = Color(0xFF00BCD4);
    expect(parseThemeHex(themeColorHex(color)), color);
  });
}
