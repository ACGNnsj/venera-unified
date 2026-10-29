import 'dart:math' as math;

import 'package:venera_unified/foundation/gallery_layout.dart';

/// Mapping between one-based image numbers and display pages.
/// Image ranges use zero-based, end-exclusive indices for List.sublist.
///
/// With [wideImages] (landscape images that must stand alone on their screen)
/// or a [grouping] computed for this chapter, the fixed [imagesPerPage]
/// arithmetic gives way to [GalleryLayout]: a landscape image gets a screen to
/// itself and grouping starts over after it. Without either, this keeps the
/// fixed arithmetic saved progress was recorded with.
class ReaderPageLayout {
  const ReaderPageLayout({
    required this.imagesPerPage,
    required this.singleImageOnFirstPage,
    this.wideImages = const {},
    this.grouping,
  }) : assert(imagesPerPage > 0);

  final int imagesPerPage;

  final bool singleImageOnFirstPage;

  /// Zero-based indices of landscape images, as they turn up while reading.
  final Set<int> wideImages;

  /// A grouping that keeps the screens already being read in place when the
  /// landscape images were discovered late. Preferred over [wideImages] when
  /// it still describes [imageCount].
  final GalleryLayout? grouping;

  bool get hasGrouping => grouping != null || wideImages.isNotEmpty;

  /// The grouping for a chapter of [imageCount] images, using [grouping] when
  /// it describes that many images and the same per-screen settings.
  GalleryLayout galleryLayout(int imageCount) {
    final override = grouping;
    if (override != null &&
        override.imageCount == imageCount &&
        override.imagesPerScreen == imagesPerPage &&
        override.singleFirst == singleImageOnFirstPage) {
      return override;
    }
    return GalleryLayout(
      imageCount: imageCount,
      imagesPerScreen: imagesPerPage,
      singleFirst: singleImageOnFirstPage,
      wide: wideImages,
    );
  }

  /// Null means images have not loaded; preserve the loading placeholder page.
  int pageCount(int? imageCount) {
    if (imageCount == null) return 1;
    if (!hasGrouping || imageCount == 0) {
      return singleImageOnFirstPage
          ? 1 + ((imageCount - 1) / imagesPerPage).ceil()
          : (imageCount / imagesPerPage).ceil();
    }
    return galleryLayout(imageCount).screenCount;
  }

  int pageForImage(int imageNumber) {
    if (imageNumber < 1) return 0;
    final override = grouping;
    if (override != null && imageNumber <= override.imageCount) {
      return override.screenOf(imageNumber - 1);
    }
    if (hasGrouping) {
      final layout = galleryLayout(imageNumber);
      if (imageNumber <= layout.imageCount) {
        return layout.screenOf(imageNumber - 1);
      }
    }
    if (imagesPerPage == 1) return imageNumber;
    return singleImageOnFirstPage
        ? ((imageNumber - 1) / imagesPerPage).ceil() + 1
        : (imageNumber / imagesPerPage).ceil();
  }

  int firstImageOnPage(int page) {
    final override = grouping;
    if (override != null && page >= 1 && page <= override.screenCount) {
      return override.imagesOf(page).$1 + 1;
    }
    if (hasGrouping && page >= 1) {
      // Every screen holds at least one image, so the page's first image is
      // never beyond this bound; the layout up to it is unaffected by the
      // images after it.
      final layout = galleryLayout((page - 1) * imagesPerPage + 1);
      return layout.imagesOf(page).$1 + 1;
    }
    if (singleImageOnFirstPage && page != 1) {
      return (page - 2) * imagesPerPage + 2;
    }
    return (page - 1) * imagesPerPage + 1;
  }

  (int start, int end) imageRange(int page, int imageCount) {
    // A cover-only empty chapter retains its legacy placeholder page count,
    // but has no source image for rendering or prefetch to index.
    if (imageCount == 0) return (0, 0);
    if (!hasGrouping) {
      if (singleImageOnFirstPage && page == 1) return (0, 1);
      final start = firstImageOnPage(page) - 1;
      return (start, math.min(start + imagesPerPage, imageCount));
    }
    return galleryLayout(imageCount).imagesOf(page);
  }

  /// Finishing the last display page (or its comments page) marks the last image.
  int historyImage(int page, int imageCount) {
    if (!hasGrouping) {
      return page >= pageCount(imageCount)
          ? imageCount
          : firstImageOnPage(page);
    }
    final layout = galleryLayout(imageCount);
    if (imageCount == 0 || page >= layout.screenCount) return imageCount;
    return layout.imagesOf(page).$1 + 1;
  }

  /// Keep the first image visible across layouts, or preserve the trailing
  /// comments page. This does not change chapter IDs or waterfall segments.
  int remapPage(int page, ReaderPageLayout target, {required int? imageCount}) {
    final targetCount = target.pageCount(imageCount);
    if (page > pageCount(imageCount)) return targetCount + 1;
    return target
        .pageForImage(firstImageOnPage(page))
        .clamp(1, math.max(1, targetCount));
  }

  /// Whether both layouts group images into the same screens.
  bool sameScreensAs(ReaderPageLayout other) {
    if (imagesPerPage != other.imagesPerPage ||
        singleImageOnFirstPage != other.singleImageOnFirstPage) {
      return false;
    }
    final mine = grouping;
    final theirs = other.grouping;
    if (mine != null && theirs != null) return mine.sameScreensAs(theirs);
    final count = mine?.imageCount ?? theirs?.imageCount;
    if (count != null) {
      final a = mine ?? galleryLayout(count);
      final b = theirs ?? other.galleryLayout(count);
      return a.sameScreensAs(b);
    }
    return wideImages.length == other.wideImages.length &&
        wideImages.containsAll(other.wideImages);
  }
}
