import 'dart:typed_data';

/// Raw RGBA bitmap that can cross isolate boundaries.
///
/// Ported from VeneraX `translation_types.dart` (subset: the translation
/// rendering cache types stay in phase 2).
class RgbaImage {
  RgbaImage(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint8List pixels;
}

/// Integer rectangle (isolate-friendly, no dart:ui types).
class IntRect {
  IntRect(this.left, this.top, this.right, this.bottom);

  int left, top, right, bottom;

  int get width => right - left;
  int get height => bottom - top;
  int get area => width * height;

  bool intersects(IntRect other) {
    return left < other.right &&
        other.left < right &&
        top < other.bottom &&
        other.top < bottom;
  }

  IntRect inflated(int dx, int dy, int maxW, int maxH) {
    return IntRect(
      (left - dx).clamp(0, maxW),
      (top - dy).clamp(0, maxH),
      (right + dx).clamp(0, maxW),
      (bottom + dy).clamp(0, maxH),
    );
  }
}

/// One recognized text block, produced by the worker isolate.
class OcrBlock {
  OcrBlock({
    required this.rect,
    IntRect? eraseRect,
    List<IntRect>? eraseRects,
    required this.text,
    required this.language,
    required this.backgroundColor,
    required this.textColor,
    this.lineHeight = 0,
  }) : eraseRect = eraseRect ?? rect,
       eraseRects = eraseRects ?? [eraseRect ?? rect];

  /// Area available to the translated lettering.
  final IntRect rect;

  /// Tighter detected-source area used only for removing the original glyphs.
  final IntRect eraseRect;

  /// Individual detected text-line areas. Keeping gaps out of these masks
  /// prevents nearby artwork inside the block bounds from being erased.
  final List<IntRect> eraseRects;

  /// Recognized source text.
  final String text;

  /// Detected source language ('ja', 'zh', 'ko', 'en').
  final String language;

  final int backgroundColor;
  final int textColor;

  /// Median height (px) of the original text lines in this block — the source
  /// lettering's approximate font size. 0 means unknown.
  final int lineHeight;
}
