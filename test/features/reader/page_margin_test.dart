import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/reader/page_margin.dart';

void main() {
  test('fraction is zero unless enabled with a clamped percent', () {
    expect(pageMarginFraction(enabled: false, percent: 19.3), 0);
    expect(
      pageMarginFraction(enabled: true, percent: 19.3),
      closeTo(0.193, 1e-9),
    );
    expect(pageMarginFraction(enabled: true, percent: 0), 0);
    expect(pageMarginFraction(enabled: true, percent: 40), 0.4);
    expect(pageMarginFraction(enabled: true, percent: 50), 0.4);
    expect(pageMarginFraction(enabled: true, percent: -5), 0);
  });

  test('fraction falls back to prime default on unusable values', () {
    expect(
      pageMarginFraction(enabled: true, percent: double.nan),
      closeTo(0.193, 1e-9),
    );
    expect(
      pageMarginFraction(enabled: true, percent: double.infinity),
      closeTo(0.193, 1e-9),
    );
  });

  test('gallery margin insets all four sides per axis', () {
    final margin = resolveGalleryPageMargin(
      fraction: 0.1,
      viewport: const Size(800, 600),
    );
    expect(margin, const EdgeInsets.fromLTRB(80, 60, 80, 60));
    expect(
      resolveGalleryPageMargin(fraction: 0, viewport: const Size(800, 600)),
      EdgeInsets.zero,
    );
    expect(
      resolveGalleryPageMargin(
        fraction: 0.9,
        viewport: const Size(800, 600),
      ),
      const EdgeInsets.fromLTRB(320, 240, 320, 240),
    );
  });

  test('continuous margin narrows across the scrolling axis', () {
    final vertical = resolveContinuousPageMargin(
      fraction: 0.1,
      vertical: true,
    );
    expect(vertical.widthScale, closeTo(0.8, 1e-9));
    expect(vertical.heightScale, 1.0);
    final horizontal = resolveContinuousPageMargin(
      fraction: 0.1,
      vertical: false,
    );
    expect(horizontal.widthScale, 1.0);
    expect(horizontal.heightScale, closeTo(0.8, 1e-9));
    expect(
      resolveContinuousPageMargin(fraction: 0, vertical: true),
      (widthScale: 1.0, heightScale: 1.0),
    );
    expect(
      resolveContinuousPageMargin(fraction: 0, vertical: false),
      (widthScale: 1.0, heightScale: 1.0),
    );
  });

  test('page-turn flash is paged-only', () {
    expect(shouldFlashOnPageTurn(enabled: true, gallery: true), isTrue);
    expect(shouldFlashOnPageTurn(enabled: true, gallery: false), isFalse);
    expect(shouldFlashOnPageTurn(enabled: false, gallery: true), isFalse);
    expect(shouldFlashOnPageTurn(enabled: false, gallery: false), isFalse);
  });
}
