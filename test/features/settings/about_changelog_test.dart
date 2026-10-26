import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/settings/settings.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/release_version.dart';
import 'package:venera_unified/foundation/appdata.dart';

void main() {
  Object? previousLanguage;
  setUp(() {
    previousLanguage = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
  });
  tearDown(() => appdata.settings['language'] = previousLanguage);

  test('stable users are not notified about prerelease versions', () {
    expect(shouldNotifyRelease('1.10.0-rc.2', '1.9.3'), isFalse);
    expect(allowsPrereleaseUpdates('1.9.3'), isFalse);
  });

  test('prerelease users are notified about newer prereleases', () {
    expect(shouldNotifyRelease('1.10.0-rc.2', '1.10.0-rc.1'), isTrue);
    expect(allowsPrereleaseUpdates('1.10.0-rc.1'), isTrue);
  });

  test('stable releases still notify stable users', () {
    expect(shouldNotifyRelease('1.10.0', '1.9.3'), isTrue);
  });

  test('stable channel selects only published stable releases', () {
    final releases = [
      {'tag_name': 'v1.11.0-rc.2', 'draft': false, 'prerelease': true},
      {'tag_name': 'v1.10.1', 'draft': true, 'prerelease': false},
      {'tag_name': 'v1.10.0', 'draft': false, 'prerelease': false},
    ];

    expect(
      selectPublishedReleaseVersion(releases, includePrerelease: false),
      '1.10.0',
    );
    expect(
      selectPublishedReleaseVersion(releases, includePrerelease: true),
      '1.11.0-rc.2',
    );
  });

  testWidgets('changelog page renders markdown content', (tester) async {
    appdata.settings['language'] = 'zh-CN';
    await AppTranslation.init();
    // Larger assets are decoded in an isolate, outside the widget test clock.
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: ChangelogPage()));
      await rootBundle.loadString('CHANGELOG.md');
      await tester.pump();
    });
    await tester.pumpAndSettle();

    expect(find.text('更新日志'), findsWidgets);
    expect(find.text('# 更新日志'), findsNothing);
    expect(find.text('变更'), findsNothing);
    expect(find.byType(ChoiceChip), findsWidgets);
    expect(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(SliverList),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((widget) => widget is Text && widget.data == '•'),
      findsWidgets,
    );
  });

  testWidgets('only builds selected version and visible markdown lines', (
    tester,
  ) async {
    final document =
        '## v2.0.0\n${List.generate(1000, (i) => '- Current entry $i').join('\n')}\n'
        '${List.generate(300, (i) => '## v1.$i.0\n- Old entry $i\n').join()}';
    final bundle = _ChangelogBundle(() async => document);
    await tester.pumpWidget(_host(bundle));
    await tester.pumpAndSettle();
    expect(find.text('Current entry 0'), findsOneWidget);
    expect(find.text('Current entry 999', skipOffstage: false), findsNothing);
    expect(find.text('Old entry 0', skipOffstage: false), findsNothing);
    expect(find.byType(ChoiceChip).evaluate().length, lessThan(20));
    expect(find.byType(Text).evaluate().length, lessThan(100));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('changelog-version-1')));
    await tester.pumpAndSettle();
    expect(find.text('Old entry 0'), findsOneWidget);
    expect(
      find.textContaining('Current entry', skipOffstage: false),
      findsNothing,
    );
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!
          .offset,
      0,
    );
    await tester.tap(find.byKey(const ValueKey('changelog-version-0')));
    await tester.pumpAndSettle();
    expect(find.text('Current entry 0'), findsOneWidget);
    expect(bundle.loads, 1);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(375, 800), const Size(850, 420)]) {
    for (final brightness in Brightness.values) {
      testWidgets('version tabs fit $size $brightness with large text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bundle = _ChangelogBundle(
          () async =>
              '## v2.0.0\n### Fixed\n- A long update message that wraps on small screens.\n## v1.0.0\n- Old entry',
        );
        await tester.pumpWidget(
          _host(bundle, brightness: brightness, textScale: 3),
        );
        await tester.pumpAndSettle();
        final semantics = tester.ensureSemantics();
        expect(
          tester.getSize(find.byType(ChoiceChip).first).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.widget<ChoiceChip>(find.byType(ChoiceChip).first).selected,
          isTrue,
        );
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }

  testWidgets('empty document and failed load offer useful states and retry', (
    tester,
  ) async {
    var attempts = 0;
    final bundle = _ChangelogBundle(() async {
      if (attempts++ == 0) throw StateError('asset unavailable');
      return '';
    });
    await tester.pumpWidget(_host(bundle));
    await tester.pumpAndSettle();
    expect(find.text('Error'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No changelog available'), findsOneWidget);
    expect(bundle.loads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'theme and text-size changes retain the selected version and asset',
    (tester) async {
      final bundle = _ChangelogBundle(
        () async => '## v2.0.0\n- New entry\n## v1.0.0\n- Old entry',
      );
      await tester.pumpWidget(_host(bundle));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('changelog-version-1')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _host(bundle, brightness: Brightness.dark, textScale: 1.8),
      );
      await tester.pumpAndSettle();
      expect(find.text('Old entry'), findsOneWidget);
      expect(find.text('New entry', skipOffstage: false), findsNothing);
      expect(bundle.loads, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late load after leaving does not update a disposed page', (
    tester,
  ) async {
    final pending = Completer<String>();
    await tester.pumpWidget(_host(_ChangelogBundle(() => pending.future)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    pending.complete('## v1.0.0\n- Loaded late');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Widget _host(
  AssetBundle bundle, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  home: DefaultAssetBundle(
    bundle: bundle,
    child: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
          padding: const EdgeInsets.only(bottom: 24),
        ),
        child: const ChangelogPage(),
      ),
    ),
  ),
);

class _ChangelogBundle extends CachingAssetBundle {
  _ChangelogBundle(this.read);
  final Future<String> Function() read;
  var loads = 0;

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    if (key != 'CHANGELOG.md') return rootBundle.loadString(key, cache: cache);
    loads++;
    return read();
  }

  @override
  Future<ByteData> load(String key) => rootBundle.load(key);
}
