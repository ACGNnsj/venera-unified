import 'package:flutter/painting.dart';

/// Pure page-margin math ported from venera-prime's utils/reader_appearance.
///
/// Paged (gallery) and continuous readers branch here: paged pages inset on
/// all four sides, while continuous readers narrow across the scrolling axis
/// so pages still join along it.
double pageMarginFraction({required bool enabled, required double percent}) {
  if (!enabled) return 0;
  // Prime falls back to its 19.3 default when the stored value is unusable.
  if (!percent.isFinite) return 0.193;
  return percent.clamp(0.0, 40.0) / 100;
}

/// Paged insets, per axis like prime: horizontal scales with viewport width,
/// vertical with viewport height.
EdgeInsets resolveGalleryPageMargin({
  required double fraction,
  required Size viewport,
}) {
  final clamped = fraction.clamp(0.0, 0.4);
  if (clamped <= 0) return EdgeInsets.zero;
  final horizontal = viewport.width * clamped;
  final vertical = viewport.height * clamped;
  return EdgeInsets.fromLTRB(horizontal, vertical, horizontal, vertical);
}

/// Scale factors for the continuous reading area. Vertical scrolling narrows
/// the width; horizontal scrolling narrows the height.
({double widthScale, double heightScale}) resolveContinuousPageMargin({
  required double fraction,
  required bool vertical,
}) {
  final clamped = fraction.clamp(0.0, 0.4);
  if (clamped <= 0) return (widthScale: 1.0, heightScale: 1.0);
  final scale = 1 - clamped * 2;
  return vertical
      ? (widthScale: scale, heightScale: 1.0)
      : (widthScale: 1.0, heightScale: scale);
}

/// The white page-turn flash applies to paged modes only; continuous readers
/// have no discrete page turns.
bool shouldFlashOnPageTurn({required bool enabled, required bool gallery}) =>
    enabled && gallery;
