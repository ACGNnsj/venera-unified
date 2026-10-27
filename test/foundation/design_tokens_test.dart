import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/design_tokens.dart';

void main() {
  test('spacing follows the 4px grid', () {
    expect(AppSpace.xs, 4);
    expect(AppSpace.sm, 8);
    expect(AppSpace.md, 12);
    expect(AppSpace.lg, 16);
    expect(AppSpace.xl, 24);
  });

  test('radius follows the M3 shape scale', () {
    expect(AppRadius.sm, 4);
    expect(AppRadius.md, 8);
    expect(AppRadius.lg, 12);
    expect(AppRadius.xl, 16);
    expect(AppRadius.xxl, 28);
    expect(AppRadius.full, 999);
  });

  test('motion durations match the M3 spec buckets', () {
    expect(AppMotion.short, const Duration(milliseconds: 200));
    expect(AppMotion.medium, const Duration(milliseconds: 300));
    expect(AppMotion.long, const Duration(milliseconds: 500));
  });

  test('motion curves use the emphasized family', () {
    expect(AppMotion.emphasized, Curves.easeInOutCubicEmphasized);
    expect(AppMotion.decelerate, Curves.easeOutCubic);
  });
}
