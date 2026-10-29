import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'ocr_types.dart';
import 'ort_ffi.dart';

/// Request handed to the OCR worker. All fields cross isolate boundaries.
class OcrPageRequest {
  OcrPageRequest({
    required this.pixels,
    required this.width,
    required this.height,
    required this.detector,
    required this.recModel,
    required this.recDict,
    this.recHeight = 48,
    this.intraOpThreads,
  });

  final TransferableTypedData pixels;
  final int width;
  final int height;
  final String detector;
  final String recModel;
  final String recDict;
  final int recHeight;
  final int? intraOpThreads;
}

/// Recognizes one page: detect -> cluster -> recognize. Runs inside
/// `Isolate.run`; blocking ORT calls are fine here.
///
/// Ported from VeneraX `translation_worker.dart`, cut down to the single
/// Japanese PP-OCRv4 line engine this release ships: no engine chain, no manga
/// OCR, no page-level engine hint, no translation or rendering stages.
List<OcrBlock> runOcrPage(OcrPageRequest req) {
  var worker = _OcrPageWorker(req.intraOpThreads);
  try {
    var pixels = req.pixels.materialize().asUint8List();
    return worker.recognize(RgbaImage(req.width, req.height, pixels), req);
  } finally {
    worker.close();
  }
}

final _letter = RegExp(r'[\p{L}\p{M}]', unicode: true);

/// Whether [rune] is a letter of any script. Lets recognition and the
/// translatable-text filter accept Cyrillic, Thai, Arabic and the like, not
/// only CJK and ASCII.
bool isScriptLetter(int rune) => _letter.hasMatch(String.fromCharCode(rune));

/// Language of an OCR block from its script. Kana decides on its own; Han
/// follows a Chinese or Japanese engine; Latin is English for the built-in
/// engines; any other script takes the engine's language.
String detectBlockLanguage(String text, String engineLang) {
  var kana = 0, hangul = 0, han = 0, latin = 0;
  for (var r in text.runes) {
    if ((r >= 0x3040 && r <= 0x30FF) || (r >= 0x31F0 && r <= 0x31FF)) {
      kana++;
    } else if ((r >= 0xAC00 && r <= 0xD7AF) || (r >= 0x1100 && r <= 0x11FF)) {
      hangul++;
    } else if ((r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF)) {
      han++;
    } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
      latin++;
    }
  }
  const builtIn = {'ja', 'zh', 'en', 'ko'};
  if (kana > 0) return 'ja';
  if (hangul > 0) return 'ko';
  if (han > 0) {
    if (engineLang == 'ja' || engineLang.startsWith('zh')) return engineLang;
    return 'zh';
  }
  if (latin > 0) return builtIn.contains(engineLang) ? 'en' : engineLang;
  return engineLang;
}

class _OcrPageWorker {
  _OcrPageWorker(this.intraOpThreads);

  final int? intraOpThreads;
  final _sessions = <String, OrtFfiSession>{};
  final _charsets = <String, List<String>>{};

  OrtFfiSession _session(String path) => _sessions.putIfAbsent(
    path,
    () => OrtFfiSession.open(path, intraOpThreads: intraOpThreads),
  );

  void close() {
    for (var session in _sessions.values) {
      session.close();
    }
    _sessions.clear();
  }

  List<OcrBlock> recognize(RgbaImage image, OcrPageRequest req) {
    var boxes = _detectBoxes(image, req);
    var clusters = clusterOcrBoxes(boxes, image.width, image.height);
    var blocks = <OcrBlock>[];
    for (var cluster in clusters) {
      var detectedBounds = _boundsOf(cluster);
      var eraseBounds = detectedBounds.inflated(
        2,
        2,
        image.width,
        image.height,
      );
      // DBNet already expands each component in post-processing. Keep the
      // individual line boxes tight; the inpainter adds its own tiny glyph
      // guard and must not reach into artwork between lines.
      var eraseLines = [
        for (var line in cluster)
          line.inflated(0, 0, image.width, image.height),
      ];
      var bounds = detectedBounds.inflated(4, 4, image.width, image.height);
      if (bounds.width < 8 || bounds.height < 8) continue;
      var colors = _sampleColors(image, bounds);
      var text = _recognizeLines(image, cluster, req).trim();
      if (!_isPlausible(text)) continue;
      var lineHeight = _medianLineHeight(cluster);
      blocks.add(
        OcrBlock(
          rect: bounds,
          eraseRect: eraseBounds,
          eraseRects: eraseLines,
          text: text,
          language: detectBlockLanguage(text, 'ja'),
          backgroundColor: colors.$1,
          textColor: colors.$2,
          lineHeight: lineHeight,
        ),
      );
    }
    return blocks;
  }

  bool _isPlausible(String text) {
    if (text.length < 2) return false;
    var meaningful = text.runes
        .where(
          (r) => r > 0x2E80 || (r >= 0x30 && r <= 0x7A) || isScriptLetter(r),
        )
        .length;
    return meaningful >= math.max(2, text.length ~/ 2);
  }

  /// Median height of a cluster's line boxes — an estimate of the original
  /// glyph height, used to size the translation to the source text.
  int _medianLineHeight(List<IntRect> lines) {
    if (lines.isEmpty) return 0;
    var heights = [for (var l in lines) l.height]..sort();
    return heights[heights.length ~/ 2];
  }

  // ----- detection -----

  List<IntRect> _detectBoxes(RgbaImage image, OcrPageRequest req) {
    var session = _session(req.detector);
    var boxes = <IntRect>[];
    const tileHeight = 1280;
    const tileOverlap = 128;
    var top = 0;
    while (top < image.height) {
      var bottom = math.min(image.height, top + tileHeight);
      var tile = RgbaImage(
        image.width,
        bottom - top,
        Uint8List.sublistView(
          image.pixels,
          top * image.width * 4,
          bottom * image.width * 4,
        ),
      );
      var input = _detPreprocess(tile);
      var output = session
          .run({
            session.inputNames.first: OrtInput.float32(input.tensor, [
              1,
              3,
              input.height,
              input.width,
            ]),
          })
          .values
          .first;
      var tileBoxes = detPostprocess(
        output.data,
        input.width,
        input.height,
        tile.width,
        tile.height,
      );
      for (var box in tileBoxes) {
        box.top += top;
        box.bottom += top;
        if (!boxes.any((b) => _iou(b, box) > 0.5)) {
          boxes.add(box);
        }
      }
      if (bottom >= image.height) break;
      top = bottom - tileOverlap;
    }
    return boxes;
  }

  // ----- Line OCR (PP-OCR CTC) -----

  String _recognizeLines(
    RgbaImage image,
    List<IntRect> lines,
    OcrPageRequest req,
  ) {
    var session = _session(req.recModel);
    var charset = _charsets.putIfAbsent('ja', () {
      var dict = File(req.recDict).readAsLinesSync();
      return ['', ...dict.map((line) => line.isEmpty ? ' ' : line), ' '];
    });
    var height = req.recHeight;
    // Vertical columns read right to left; horizontal lines top to bottom.
    var vertical = lines.any(_isVerticalLine);
    var sorted = [...lines]
      ..sort(
        (a, b) =>
            vertical ? b.right.compareTo(a.right) : a.top.compareTo(b.top),
      );
    var parts = <String>[];
    for (var line in sorted) {
      var rect = line.inflated(2, 2, image.width, image.height);
      if (rect.width < 8 || rect.height < 8) continue;
      // The line models read left to right only: a column squeezed to one
      // line height came out empty. Turned 90° counter-clockwise, its top
      // glyph lands on the left, the way PP-OCR itself feeds vertical text.
      var rotate = _isVerticalLine(rect);
      var runLength = rotate ? rect.height : rect.width;
      var thickness = rotate ? rect.width : rect.height;
      var outW = (runLength * height / math.max(1, thickness)).round().clamp(
        16,
        960,
      );
      outW = (outW / 8).ceil() * 8;
      var tensor = _normalize(
        resizeTextLine(image, rect, outW, height, rotate: rotate),
        outW,
        height,
      );
      var output = session
          .run({
            session.inputNames.first: OrtInput.float32(tensor, [
              1,
              3,
              height,
              outW,
            ]),
          })
          .values
          .first;
      var text = _ctcDecode(output.data, output.shape.last, charset);
      if (text.trim().isNotEmpty) {
        parts.add(text.trim());
      }
    }
    return parts.join(' ');
  }

  String _ctcDecode(Float32List probs, int classes, List<String> charset) {
    var steps = probs.length ~/ classes;
    var buffer = StringBuffer();
    var prev = 0;
    for (var t = 0; t < steps; t++) {
      var best = 0;
      var bestScore = probs[t * classes];
      for (var c = 1; c < classes; c++) {
        var score = probs[t * classes + c];
        if (score > bestScore) {
          bestScore = score;
          best = c;
        }
      }
      if (best != 0 && best != prev && best < charset.length) {
        buffer.write(charset[best]);
      }
      prev = best;
    }
    return buffer.toString().trim();
  }
}

// ===========================================================================
// Pure image math (worker side)
// ===========================================================================

class _DetInput {
  _DetInput(this.tensor, this.width, this.height);

  final Float32List tensor;
  final int width;
  final int height;
}

Uint8List _resizeRegion(RgbaImage src, IntRect region, int outW, int outH) {
  var out = Uint8List(outW * outH * 4);
  var srcW = region.width;
  var srcH = region.height;
  for (var y = 0; y < outH; y++) {
    var fy = (y + 0.5) * srcH / outH - 0.5;
    var y0 = fy.floor().clamp(0, srcH - 1);
    var y1 = (y0 + 1).clamp(0, srcH - 1);
    var wy = fy - fy.floor();
    for (var x = 0; x < outW; x++) {
      var fx = (x + 0.5) * srcW / outW - 0.5;
      var x0 = fx.floor().clamp(0, srcW - 1);
      var x1 = (x0 + 1).clamp(0, srcW - 1);
      var wx = fx - fx.floor();
      var outIndex = (y * outW + x) * 4;
      for (var c = 0; c < 4; c++) {
        var p00 = src
            .pixels[((region.top + y0) * src.width + region.left + x0) * 4 + c];
        var p01 = src
            .pixels[((region.top + y0) * src.width + region.left + x1) * 4 + c];
        var p10 = src
            .pixels[((region.top + y1) * src.width + region.left + x0) * 4 + c];
        var p11 = src
            .pixels[((region.top + y1) * src.width + region.left + x1) * 4 + c];
        var top = p00 + (p01 - p00) * wx;
        var bottom = p10 + (p11 - p10) * wx;
        out[outIndex + c] = (top + (bottom - top) * wy).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// PP-OCR DBNet preprocessing: long side <= 1280 (small/stylized lettering
/// survives better than at the stock 960), multiple of 32, ImageNet
/// normalization.
_DetInput _detPreprocess(RgbaImage tile) {
  const maxSide = 1280.0;
  var scale = math.min(1.0, maxSide / math.max(tile.width, tile.height));
  int round32(double v) => math.max(32, (v / 32).round() * 32);
  var inW = round32(tile.width * scale);
  var inH = round32(tile.height * scale);
  var resized = _resizeRegion(
    tile,
    IntRect(0, 0, tile.width, tile.height),
    inW,
    inH,
  );
  const mean = [0.485, 0.456, 0.406];
  const std = [0.229, 0.224, 0.225];
  var tensor = Float32List(3 * inH * inW);
  var plane = inH * inW;
  for (var i = 0; i < plane; i++) {
    for (var c = 0; c < 3; c++) {
      tensor[c * plane + i] = (resized[i * 4 + c] / 255.0 - mean[c]) / std[c];
    }
  }
  return _DetInput(tensor, inW, inH);
}

/// DBNet postprocessing: binarize, connected components, filter, dilate.
/// Public (unlike upstream) so the acceptance tests can pin it directly.
List<IntRect> detPostprocess(
  Float32List probs,
  int w,
  int h,
  int tileWidth,
  int tileHeight,
) {
  const binaryThreshold = 0.3;
  const scoreThreshold = 0.5;
  const unclipRatio = 1.8;
  var labels = Int32List(w * h);
  var boxes = <IntRect>[];
  var stack = <int>[];
  var nextLabel = 0;
  for (var start = 0; start < w * h; start++) {
    if (labels[start] != 0 || probs[start] < binaryThreshold) {
      continue;
    }
    nextLabel++;
    var minX = w, minY = h, maxX = 0, maxY = 0;
    var count = 0;
    var scoreSum = 0.0;
    stack.add(start);
    labels[start] = nextLabel;
    while (stack.isNotEmpty) {
      var index = stack.removeLast();
      var x = index % w;
      var y = index ~/ w;
      count++;
      scoreSum += probs[index];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      for (var d = 0; d < 4; d++) {
        var nx = x + const [1, -1, 0, 0][d];
        var ny = y + const [0, 0, 1, -1][d];
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        var ni = ny * w + nx;
        if (labels[ni] == 0 && probs[ni] >= binaryThreshold) {
          labels[ni] = nextLabel;
          stack.add(ni);
        }
      }
    }
    if (count < 12 || scoreSum / count < scoreThreshold) {
      continue;
    }
    var boxW = maxX - minX + 1;
    var boxH = maxY - minY + 1;
    if (boxW < 3 || boxH < 3) continue;
    var offset = boxW * boxH * unclipRatio / (2 * (boxW + boxH));
    var scaleX = tileWidth / w;
    var scaleY = tileHeight / h;
    boxes.add(
      IntRect(
        ((minX - offset) * scaleX).round(),
        ((minY - offset) * scaleY).round(),
        ((maxX + 1 + offset) * scaleX).round(),
        ((minY - offset) * scaleY).round() +
            ((boxH + 2 * offset) * scaleY).round(),
      ),
    );
  }
  return boxes;
}

/// Groups detector line boxes into OCR blocks without joining incompatible
/// neighbouring captions or speech bubbles.
List<List<IntRect>> clusterOcrBoxes(
  List<IntRect> boxes,
  int width,
  int height,
) {
  var parents = List<int>.generate(boxes.length, (i) => i);
  var minThickness = [for (var box in boxes) math.min(box.width, box.height)];
  var maxThickness = [...minThickness];
  var hasHorizontal = [for (var box in boxes) _lineDirection(box) > 0];
  var hasVertical = [for (var box in boxes) _lineDirection(box) < 0];
  var members = [
    for (var i = 0; i < boxes.length; i++) <int>[i],
  ];
  int find(int i) {
    while (parents[i] != i) {
      parents[i] = parents[parents[i]];
      i = parents[i];
    }
    return i;
  }

  var inflated = [
    for (var box in boxes)
      // Inflation controls when neighbouring lines merge into one block.
      // Too generous and two adjacent speech bubbles fuse — the combined
      // crop then squashes both into one OCR input and recognition degrades
      // badly. 0.55 of the short side still bridges the gaps between lines
      // and vertical columns inside one bubble.
      box.inflated(
        (math.min(box.width, box.height) * 0.55).round().clamp(3, 32),
        (math.min(box.width, box.height) * 0.55).round().clamp(3, 32),
        width,
        height,
      ),
  ];
  for (var i = 0; i < boxes.length; i++) {
    for (var j = i + 1; j < boxes.length; j++) {
      if (inflated[i].intersects(inflated[j]) &&
          _compatibleTextLines(boxes[i], boxes[j])) {
        var rootI = find(i);
        var rootJ = find(j);
        if (rootI == rootJ) continue;
        var mergedHorizontal = hasHorizontal[rootI] || hasHorizontal[rootJ];
        var mergedVertical = hasVertical[rootI] || hasVertical[rootJ];
        var mergedMin = math.min(minThickness[rootI], minThickness[rootJ]);
        var mergedMax = math.max(maxThickness[rootI], maxThickness[rootJ]);
        if ((mergedHorizontal && mergedVertical) ||
            mergedMax > math.max(1, mergedMin) * 2.2) {
          continue;
        }
        var direction = mergedHorizontal
            ? 1
            : mergedVertical
            ? -1
            : 0;
        if (!_compatibleTextGroups(
          members[rootI],
          members[rootJ],
          boxes,
          direction,
        )) {
          continue;
        }
        parents[rootJ] = rootI;
        members[rootI].addAll(members[rootJ]);
        minThickness[rootI] = mergedMin;
        maxThickness[rootI] = mergedMax;
        hasHorizontal[rootI] = mergedHorizontal;
        hasVertical[rootI] = mergedVertical;
      }
    }
  }
  var groups = <int, List<IntRect>>{};
  for (var i = 0; i < boxes.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(boxes[i]);
  }
  return groups.values.toList();
}

int _lineDirection(IntRect box) {
  if (box.width >= box.height * 1.25) return 1;
  if (box.height >= box.width * 1.25) return -1;
  return 0;
}

bool _compatibleTextLines(IntRect a, IntRect b) {
  var directionA = _lineDirection(a);
  var directionB = _lineDirection(b);
  if (directionA != 0 && directionB != 0 && directionA != directionB) {
    return false;
  }

  var thicknessA = math.min(a.width, a.height);
  var thicknessB = math.min(b.width, b.height);
  if (math.max(thicknessA, thicknessB) >
      math.max(1, math.min(thicknessA, thicknessB)) * 2.2) {
    return false;
  }

  var direction = directionA != 0 ? directionA : directionB;
  if (direction > 0) {
    var stacked =
        _axisOverlap(a.left, a.right, b.left, b.right) >=
        math.min(a.width, b.width) * 0.25;
    var shortFragments =
        a.width <= thicknessA * 12 && b.width <= thicknessB * 12;
    var sameLine =
        shortFragments &&
        _axisOverlap(a.top, a.bottom, b.top, b.bottom) >=
            math.min(a.height, b.height) * 0.6 &&
        _axisGap(a.left, a.right, b.left, b.right) <=
            _sameLineGap(thicknessA, thicknessB);
    return stacked || sameLine;
  }
  if (direction < 0) {
    var adjacentColumns =
        _axisOverlap(a.top, a.bottom, b.top, b.bottom) >=
        math.min(a.height, b.height) * 0.25;
    var shortFragments =
        a.height <= thicknessA * 12 && b.height <= thicknessB * 12;
    var sameColumn =
        shortFragments &&
        _axisOverlap(a.left, a.right, b.left, b.right) >=
            math.min(a.width, b.width) * 0.6 &&
        _axisGap(a.top, a.bottom, b.top, b.bottom) <=
            _sameLineGap(thicknessA, thicknessB);
    return adjacentColumns || sameColumn;
  }
  return true;
}

bool _compatibleTextGroups(
  List<int> groupA,
  List<int> groupB,
  List<IntRect> boxes,
  int direction,
) {
  for (var indexA in groupA) {
    for (var indexB in groupB) {
      var a = boxes[indexA];
      var b = boxes[indexB];
      if (direction > 0) {
        var sameLine =
            _axisOverlap(a.top, a.bottom, b.top, b.bottom) >=
            math.min(a.height, b.height) * 0.6;
        if (!sameLine &&
            _axisOverlap(a.left, a.right, b.left, b.right) <
                math.min(a.width, b.width) * 0.25) {
          return false;
        }
      } else if (direction < 0) {
        var sameColumn =
            _axisOverlap(a.left, a.right, b.left, b.right) >=
            math.min(a.width, b.width) * 0.6;
        if (!sameColumn &&
            _axisOverlap(a.top, a.bottom, b.top, b.bottom) <
                math.min(a.height, b.height) * 0.25) {
          return false;
        }
      } else if (!_compatibleTextLines(a, b)) {
        return false;
      }
    }
  }
  return true;
}

int _axisOverlap(int startA, int endA, int startB, int endB) =>
    math.max(0, math.min(endA, endB) - math.max(startA, startB));

int _axisGap(int startA, int endA, int startB, int endB) =>
    math.max(0, math.max(startA, startB) - math.min(endA, endB));

/// Largest run-direction gap two fragments of one line may have. Word spacing
/// and detector splits routinely leave most of a glyph height between pieces,
/// so this sits close to the line thickness rather than well below it.
double _sameLineGap(int thicknessA, int thicknessB) =>
    math.max(thicknessA, thicknessB) * 0.8;

IntRect _boundsOf(List<IntRect> boxes) {
  var result = IntRect(
    boxes[0].left,
    boxes[0].top,
    boxes[0].right,
    boxes[0].bottom,
  );
  for (var box in boxes.skip(1)) {
    result.left = math.min(result.left, box.left);
    result.top = math.min(result.top, box.top);
    result.right = math.max(result.right, box.right);
    result.bottom = math.max(result.bottom, box.bottom);
  }
  return result;
}

/// A detected line taller than wide by PP-OCR's own margin: a vertical column.
bool _isVerticalLine(IntRect r) => r.height >= r.width * 1.5;

/// Resamples [region] to [outW]x[outH] RGBA. With [rotate] the region is
/// turned 90° counter-clockwise first, so a vertical column reads left to
/// right with its top glyph first.
@visibleForTesting
Uint8List resizeTextLine(
  RgbaImage src,
  IntRect region,
  int outW,
  int outH, {
  bool rotate = false,
}) {
  if (!rotate) return _resizeRegion(src, region, outW, outH);
  var out = Uint8List(outW * outH * 4);
  var srcW = region.width;
  var srcH = region.height;
  for (var y = 0; y < outH; y++) {
    // Output rows walk the source columns from right to left.
    var fx = srcW - 0.5 - (y + 0.5) * srcW / outH;
    var x0 = fx.floor().clamp(0, srcW - 1);
    var x1 = (x0 + 1).clamp(0, srcW - 1);
    var wx = fx - fx.floor();
    for (var x = 0; x < outW; x++) {
      // Output columns walk the source rows from top to bottom.
      var fy = (x + 0.5) * srcH / outW - 0.5;
      var y0 = fy.floor().clamp(0, srcH - 1);
      var y1 = (y0 + 1).clamp(0, srcH - 1);
      var wy = fy - fy.floor();
      var outIndex = (y * outW + x) * 4;
      for (var c = 0; c < 4; c++) {
        int px(int sy, int sx) =>
            src.pixels[((region.top + sy) * src.width + region.left + sx) * 4 +
                c];
        var top = px(y0, x0) + (px(y0, x1) - px(y0, x0)) * wx;
        var bottom = px(y1, x0) + (px(y1, x1) - px(y1, x0)) * wx;
        out[outIndex + c] = (top + (bottom - top) * wy).round().clamp(0, 255);
      }
    }
  }
  return out;
}

Float32List _normalize(Uint8List resized, int outW, int outH) {
  var tensor = Float32List(3 * outH * outW);
  var plane = outH * outW;
  for (var i = 0; i < plane; i++) {
    for (var c = 0; c < 3; c++) {
      tensor[c * plane + i] = (resized[i * 4 + c] / 255.0 - 0.5) / 0.5;
    }
  }
  return tensor;
}

/// Estimates (backgroundColor, textColor) for a region by separating the two
/// dominant colour classes inside it.
///
/// The block's pixels split into a background class (bubble fill, the larger
/// share) and a text class (the strokes). An Otsu luminance threshold labels
/// each pixel, then the mean colour of each class is taken — so the text colour
/// is the *actual* ink (a coloured SFX, a grey caption) rather than a flat
/// dark/light guess, and the background is the *actual* fill sampled from the
/// non-stroke pixels rather than a ring outside the box that may fall on
/// artwork. A ring sample still seeds the background when the split is
/// degenerate (near-uniform crop), and the returned text colour is nudged to
/// keep a minimum contrast against the background so it stays legible.
(int, int) _sampleColors(RgbaImage image, IntRect rect) {
  var w = image.width;
  var left = rect.left.clamp(0, w - 1);
  var top = rect.top.clamp(0, image.height - 1);
  var right = rect.right.clamp(1, w);
  var bottom = rect.bottom.clamp(1, image.height);
  var pixels = image.pixels;

  // Stride so a big block stays cheap; small blocks read every pixel.
  var stepX = math.max(1, (right - left) ~/ 48);
  var stepY = math.max(1, (bottom - top) ~/ 48);

  var lum = <int>[];
  var pr = <int>[], pg = <int>[], pb = <int>[];
  for (var y = top; y < bottom; y += stepY) {
    for (var x = left; x < right; x += stepX) {
      var i = (y * w + x) * 4;
      var r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
      pr.add(r);
      pg.add(g);
      pb.add(b);
      lum.add((0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255));
    }
  }

  int ringMedianColor() {
    var ring = rect.inflated(6, 6, w, image.height);
    var rs = <int>[], gs = <int>[], bs = <int>[];
    void s(int x, int y) {
      var i = (y * w + x) * 4;
      rs.add(pixels[i]);
      gs.add(pixels[i + 1]);
      bs.add(pixels[i + 2]);
    }

    for (var x = ring.left; x < ring.right; x += 3) {
      s(x, ring.top);
      s(x, ring.bottom - 1);
    }
    for (var y = ring.top; y < ring.bottom; y += 3) {
      s(ring.left, y);
      s(ring.right - 1, y);
    }
    int med(List<int> v) {
      if (v.isEmpty) return 255;
      v.sort();
      return v[v.length ~/ 2];
    }

    return 0xFF000000 | (med(rs) << 16) | (med(gs) << 8) | med(bs);
  }

  if (lum.length < 8) {
    var bg = ringMedianColor();
    var bgLum =
        0.299 * ((bg >> 16) & 0xFF) +
        0.587 * ((bg >> 8) & 0xFF) +
        0.114 * (bg & 0xFF);
    return (bg, bgLum < 128 ? 0xFFF5F5F5 : 0xFF202020);
  }

  var threshold = _otsuOf(lum);
  var loSumR = 0, loSumG = 0, loSumB = 0, loN = 0;
  var hiSumR = 0, hiSumG = 0, hiSumB = 0, hiN = 0;
  for (var i = 0; i < lum.length; i++) {
    if (lum[i] <= threshold) {
      loSumR += pr[i];
      loSumG += pg[i];
      loSumB += pb[i];
      loN++;
    } else {
      hiSumR += pr[i];
      hiSumG += pg[i];
      hiSumB += pb[i];
      hiN++;
    }
  }

  // The background is the larger class; text is the smaller. A block that is
  // almost entirely one class (no real strokes visible) falls back to the ring.
  if (loN == 0 || hiN == 0) {
    var bg = ringMedianColor();
    var bgLum =
        0.299 * ((bg >> 16) & 0xFF) +
        0.587 * ((bg >> 8) & 0xFF) +
        0.114 * (bg & 0xFF);
    return (bg, bgLum < 128 ? 0xFFF5F5F5 : 0xFF202020);
  }

  int packMean(int sr, int sg, int sb, int n) =>
      0xFF000000 | ((sr ~/ n) << 16) | ((sg ~/ n) << 8) | (sb ~/ n);
  var loColor = packMean(loSumR, loSumG, loSumB, loN);
  var hiColor = packMean(hiSumR, hiSumG, hiSumB, hiN);

  // Background = majority class, text = minority class.
  int bgColor, textColor;
  if (loN >= hiN) {
    bgColor = loColor;
    textColor = hiColor;
  } else {
    bgColor = hiColor;
    textColor = loColor;
  }

  textColor = _ensureContrast(textColor, bgColor);
  return (bgColor, textColor);
}

/// Otsu threshold over a luminance sample list.
int _otsuOf(List<int> lum) {
  var hist = Int32List(256);
  for (var l in lum) {
    hist[l]++;
  }
  var total = lum.length;
  var sum = 0.0;
  for (var t = 0; t < 256; t++) {
    sum += t * hist[t];
  }
  var sumB = 0.0;
  var wB = 0;
  var maxVar = -1.0;
  var threshold = 127;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    var wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    var mB = sumB / wB;
    var mF = (sum - sumB) / wF;
    var between = wB * wF * (mB - mF) * (mB - mF);
    if (between > maxVar) {
      maxVar = between;
      threshold = t;
    }
  }
  return threshold;
}

/// Nudges [text] away from [bg] when their luminance is too close, so the drawn
/// text stays readable. Keeps [text]'s hue, only pushing it darker or lighter.
int _ensureContrast(int text, int bg) {
  double lumOf(int c) =>
      0.299 * ((c >> 16) & 0xFF) +
      0.587 * ((c >> 8) & 0xFF) +
      0.114 * (c & 0xFF);
  var tl = lumOf(text);
  var bl = lumOf(bg);
  if ((tl - bl).abs() >= 60) return text;
  // Too close: fall back to a high-contrast neutral against the background.
  return bl < 128 ? 0xFFF5F5F5 : 0xFF202020;
}

double _iou(IntRect a, IntRect b) {
  var left = math.max(a.left, b.left);
  var top = math.max(a.top, b.top);
  var right = math.min(a.right, b.right);
  var bottom = math.min(a.bottom, b.bottom);
  if (left >= right || top >= bottom) return 0;
  var inter = (right - left) * (bottom - top);
  return inter / (a.area + b.area - inter);
}
