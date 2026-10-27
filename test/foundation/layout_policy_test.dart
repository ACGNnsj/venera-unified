import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/layout_policy.dart';

void main() {
  group('favoritesUsesSplitPane', () {
    test('720dp and below stay single-pane (zero-regression line)', () {
      for (var w = 320; w <= 720; w++) {
        expect(favoritesUsesSplitPane(w.toDouble()), isFalse, reason: '$w');
      }
    });

    test('above 720dp enters split pane without gaps', () {
      expect(favoritesUsesSplitPane(720.01), isTrue);
      for (var w = 721; w <= 2000; w += 7) {
        expect(favoritesUsesSplitPane(w.toDouble()), isTrue, reason: '$w');
      }
    });

    test('breakpoint value is pinned', () {
      expect(favoritesSplitPaneBreakpoint, 720.0);
    });
  });

  group('favoritesPaneWeights', () {
    test('closed detail takes no share', () {
      final (list, detail) = favoritesPaneWeights(detailOpen: false);
      expect(detail, 0.0);
      expect(list / (list + detail), 1.0);
    });

    test('open detail keeps 1:2 ratio', () {
      final (list, detail) = favoritesPaneWeights(detailOpen: true);
      expect(detail / list, closeTo(2.0, 1e-9));
    });

    test('opening detail only narrows the list', () {
      final (openList, openDetail) = favoritesPaneWeights(detailOpen: true);
      final (closedList, closedDetail) = favoritesPaneWeights(
        detailOpen: false,
      );
      final openShare = openList / (openList + openDetail);
      final closedShare = closedList / (closedList + closedDetail);
      expect(openShare, lessThan(closedShare));
    });
  });

  group('favoritesPaneWidths', () {
    test('closed detail eats full width', () {
      expect(favoritesPaneWidths(totalWidth: 1000, detailOpen: false), (
        1000.0,
        0.0,
      ));
    });

    test('open detail splits 1:2 under the cap', () {
      expect(favoritesPaneWidths(totalWidth: 900, detailOpen: true), (
        300.0,
        600.0,
      ));
    });

    test('list pane is capped and overflow goes right', () {
      expect(favoritesListPaneMaxWidth, 360.0);
      final (list, detail) = favoritesPaneWidths(
        totalWidth: 1500,
        detailOpen: true,
      );
      expect(list, 360.0);
      expect(detail, 1140.0);
      expect(list + detail, 1500.0);
    });

    test('cap boundary is continuous', () {
      // 1080 / 3 == 360: exactly at the cap from below and above.
      final (belowList, _) = favoritesPaneWidths(
        totalWidth: 1079.99,
        detailOpen: true,
      );
      expect(belowList, lessThan(360.0));
      final (aboveList, aboveDetail) = favoritesPaneWidths(
        totalWidth: 1080.01,
        detailOpen: true,
      );
      expect(aboveList, 360.0);
      expect(aboveDetail, closeTo(720.01, 1e-9));
    });

    test('non-positive width yields nothing', () {
      expect(favoritesPaneWidths(totalWidth: 0, detailOpen: true), (0.0, 0.0));
      expect(favoritesPaneWidths(totalWidth: -10, detailOpen: false), (
        0.0,
        0.0,
      ));
    });
  });
}
