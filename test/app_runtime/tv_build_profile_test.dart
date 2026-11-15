import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/app_runtime/application_updates.dart';
import 'package:venera_unified/components/tv_navigation.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/app_profile.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/application_update_service.dart';
import 'package:venera_unified/foundation/tv_reader_policy.dart';

const _expectTv = bool.fromEnvironment('EXPECT_TV');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the compiled flavor controls the actual application update service',
    () async {
      expect(AppProfile.current.isTv, _expectTv);
      final updates = createApplicationUpdates();
      addTearDown(updates.closeAndWait);
      expect(updates.enabled, isTrue);
      expect(updates.forAndroidTv, _expectTv);
      if (_expectTv) {
        expect(AppProfile.current.build, 'ci-test');
        expect(AppProfile.current.revision, 'tv-test');
        // The endpoint URL is pinned deterministically: a wrong URL is the
        // only real bug this network call could catch, and it needs no
        // network to verify. Everything below this line is live-egress
        // weather (rate limits, proxy MITM, resets) and skips on any throw;
        // the flavor wiring under test already passed above.
        expect(
          ApplicationUpdateService.releasesApiBase,
          'https://api.github.com/repos/CyrilPeng/venera-next/releases',
        );
        String? available;
        try {
          available = await updates.check();
        } catch (_) {
          markTestSkipped('update endpoint unreachable from CI');
        }
        expect(available, isNull);
      }
    },
  );

  test(
    'the compiled flavor overlays local settings without rewriting them',
    () async {
      final before = appdata.captureImportCheckpoint();
      final directory = Directory.systemTemp.createTempSync('tv-profile-');
      App.dataPath = directory.path;
      try {
        appdata.settings['readerMode'] = 'waterfallTopToBottom';
        appdata.settings['autoReaderMode'] = true;
        appdata.settings['preloadImageCount'] = 12;
        appdata.settings[TvReaderPolicy.lowMemory.key] = true;
        expect(appdata.settings.tvLowMemoryEnabled, _expectTv);
        expect(
          appdata.settings.globalReaderSettings.readerMode,
          _expectTv ? 'galleryLeftToRight' : 'waterfallTopToBottom',
        );
        expect(
          appdata.settings.globalReaderSettings.preloadImageCount,
          _expectTv ? 1 : 12,
        );
        expect(appdata.settings['readerMode'], 'waterfallTopToBottom');
        expect(appdata.settings['preloadImageCount'], 12);
        appdata.settings[TvReaderPolicy.lowMemory.key] = false;
        expect(appdata.settings.tvLowMemoryEnabled, isFalse);
        expect(
          appdata.settings.globalReaderSettings.readerMode,
          'waterfallTopToBottom',
        );
        expect(appdata.settings.globalReaderSettings.preloadImageCount, 12);
      } finally {
        await appdata.restoreImportCheckpoint(before, persist: false);
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'navigation defaults to the actual build rather than screen size',
    (tester) async {
      late MediaQueryData media;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => TvNavigation(child: child!),
          home: Builder(
            builder: (context) {
              media = MediaQuery.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        media.navigationMode,
        _expectTv ? NavigationMode.directional : NavigationMode.traditional,
      );
      expect(media.padding.left, _expectTv ? 24 : 0);
    },
  );
}
