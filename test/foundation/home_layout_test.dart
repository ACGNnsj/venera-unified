import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/home_layout.dart';

void main() {
  dynamic useStored(dynamic value) {
    final previous = appdata.settings['homeSections'];
    addTearDown(() => appdata.settings['homeSections'] = previous);
    appdata.settings['homeSections'] = value;
    return previous;
  }

  void useTempDataPath() {
    final dataDir = Directory.systemTemp.createTempSync('venera-home-layout-');
    addTearDown(() {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });
    App.dataPath = dataDir.path;
  }

  List<String> idsOf(List<HomeSectionConfig> layout) => [
    for (var config in layout) config.id,
  ];

  test('default layout shows every known section in table order', () {
    final layout = defaultHomeLayout();
    expect(idsOf(layout), [for (var meta in kHomeSections) meta.id]);
    expect(layout.every((config) => config.visible), isTrue);
    expect(layout.length, kHomeSections.length);
  });

  test('normalize falls back to default on missing or malformed input', () {
    useStored(null);
    expect(idsOf(normalizeHomeLayout()), idsOf(defaultHomeLayout()));
    useStored('homeSections');
    expect(idsOf(normalizeHomeLayout()), idsOf(defaultHomeLayout()));
    useStored([42, 'history', null]);
    expect(idsOf(normalizeHomeLayout()), idsOf(defaultHomeLayout()));
  });

  test('normalize keeps stored order and visibility', () {
    useStored([
      {'id': 'local', 'visible': false},
      {'id': 'history', 'visible': true},
    ]);
    final layout = normalizeHomeLayout();
    expect(idsOf(layout).take(2), ['local', 'history']);
    expect(
      layout.firstWhere((config) => config.id == 'local').visible,
      isFalse,
    );
    expect(
      layout.firstWhere((config) => config.id == 'history').visible,
      isTrue,
    );
    // Every known section still renders exactly once.
    expect(idsOf(layout).toSet().length, kHomeSections.length);
  });

  test('normalize drops unknown ids and duplicates, appends missing', () {
    useStored([
      {'id': 'history', 'visible': false},
      {'id': 'fromFutureVersion', 'visible': true},
      {'id': 'history', 'visible': true},
      {'id': 'search'},
    ]);
    final layout = normalizeHomeLayout();
    expect(idsOf(layout).take(2), ['history', 'search']);
    expect(idsOf(layout).contains('fromFutureVersion'), isFalse);
    expect(idsOf(layout).where((id) => id == 'history').length, 1);
    // First occurrence wins; missing visible flag means visible.
    expect(
      layout.firstWhere((config) => config.id == 'history').visible,
      isFalse,
    );
    expect(
      layout.firstWhere((config) => config.id == 'search').visible,
      isTrue,
    );
    // Missing known sections are appended as visible.
    expect(
      idsOf(layout).sublist(2),
      [
        for (var meta in kHomeSections) meta.id,
      ].where((id) => id != 'history' && id != 'search'),
    );
    expect(layout.skip(2).every((config) => config.visible), isTrue);
  });

  test('save preserves unknown stored ids across a round-trip', () async {
    useTempDataPath();
    useStored([
      {'id': 'history', 'visible': false},
      {'id': 'fromFutureVersion', 'visible': true},
    ]);
    final layout = normalizeHomeLayout();
    saveHomeLayout(layout);
    await appdata.saveData(false);
    final stored = appdata.settings['homeSections'];
    expect(stored, isA<List>());
    final storedIds = [
      for (var record in (stored as List)) (record as Map)['id'],
    ];
    // Reordered + migrated layout first, unknown id preserved at the end.
    expect(storedIds.take(layout.length), idsOf(layout));
    expect(storedIds.last, 'fromFutureVersion');
    // Round-trip is stable.
    expect(idsOf(normalizeHomeLayout()), idsOf(layout));
  });

  test('save writes a reorder plus a visibility toggle', () async {
    useTempDataPath();
    useStored(null);
    final layout = defaultHomeLayout();
    final history = layout.removeAt(
      layout.indexWhere((config) => config.id == 'history'),
    );
    layout.insert(0, history);
    final local = layout.indexWhere((config) => config.id == 'local');
    layout[local] = layout[local].copyWith(visible: false);
    saveHomeLayout(layout);
    await appdata.saveData(false);
    final stored = appdata.settings['homeSections'] as List;
    expect((stored.first as Map)['id'], 'history');
    final localRecord = stored.cast<Map>().firstWhere(
      (record) => record['id'] == 'local',
    );
    expect(localRecord['visible'], isFalse);
  });
}
