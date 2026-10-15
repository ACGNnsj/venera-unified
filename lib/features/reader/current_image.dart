import 'dart:ui';

typedef ReaderVisibleImage = ({int index, Rect bounds});

/// Compare occupied viewport area, not the fraction of each image on screen.
/// Ties retain the current page, then prefer the center, independent of order.
int? resolveCurrentReaderImage({
  required Iterable<ReaderVisibleImage> images,
  required Rect viewport,
  int? currentIndex,
}) {
  if (!viewport.isFinite || viewport.isEmpty) return null;
  int? best;
  var bestArea = 0.0;
  var bestDistance = double.infinity;
  const epsilon = 0.000001;
  for (final image in images) {
    if (image.index < 1 || !image.bounds.isFinite) continue;
    final visible = image.bounds.intersect(viewport);
    if (visible.isEmpty) continue;
    final area = visible.width * visible.height;
    final distance = (visible.center - viewport.center).distanceSquared;
    final sameArea = (area - bestArea).abs() <= epsilon;
    final sameDistance = (distance - bestDistance).abs() <= epsilon;
    if (best == null ||
        area > bestArea + epsilon ||
        (sameArea &&
            best != currentIndex &&
            (image.index == currentIndex ||
                distance < bestDistance - epsilon ||
                (sameDistance && image.index < best)))) {
      best = image.index;
      bestArea = area;
      bestDistance = distance;
    }
  }
  return best;
}
