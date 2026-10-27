import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/background_keepalive.dart';

void main() {
  group('formatTaskStatus', () {
    test('returns title alone without detail', () {
      expect(formatTaskStatus(title: 'Sync'), 'Sync');
    });

    test('appends detail', () {
      expect(formatTaskStatus(title: 'Sync', detail: '3/10'), 'Sync · 3/10');
    });

    test('ignores blank detail', () {
      expect(formatTaskStatus(title: 'Sync', detail: '  '), 'Sync');
    });
  });

  group('syncKeepAliveActive', () {
    test('false when everything is clear', () {
      expect(
        syncKeepAliveActive(
          uploading: false,
          downloading: false,
          syncingImages: false,
          waiting: false,
        ),
        isFalse,
      );
    });

    test('true when any flag is set', () {
      const flags = [
        (true, false, false, false),
        (false, true, false, false),
        (false, false, true, false),
        (false, false, false, true),
      ];
      for (final (u, d, i, w) in flags) {
        expect(
          syncKeepAliveActive(
            uploading: u,
            downloading: d,
            syncingImages: i,
            waiting: w,
          ),
          isTrue,
        );
      }
    });
  });

  group('BackgroundKeepAlive channel', () {
    const channel = MethodChannel('venera/background_keepalive');
    final calls = <MethodCall>[];
    var granted = true;
    var updateResult = true;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      BackgroundKeepAlive.debugSupported = true;
      BackgroundKeepAlive.instance.debugReset();
      calls.clear();
      granted = true;
      updateResult = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'notificationGranted' => granted,
              'requestNotification' => granted = true,
              'update' => updateResult,
              _ => null,
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      BackgroundKeepAlive.debugSupported = null;
      BackgroundKeepAlive.instance.debugReset();
    });

    test('update pushes once and dedupes repeats', () async {
      BackgroundKeepAlive.instance.update('sync', 'Sync · 1/2');
      BackgroundKeepAlive.instance.update('sync', 'Sync · 1/2');
      await Future<void>.delayed(Duration.zero);

      final updates = calls.where((c) => c.method == 'update').toList();
      expect(updates, hasLength(1));
      expect(updates.single.arguments['tag'], 'sync');
    });

    test('remove drops the tag and notifies once', () async {
      BackgroundKeepAlive.instance.update('sync', 'Sync');
      await Future<void>.delayed(Duration.zero);
      BackgroundKeepAlive.instance.remove('sync');
      BackgroundKeepAlive.instance.remove('sync');
      await Future<void>.delayed(Duration.zero);

      final removes = calls.where((c) => c.method == 'remove').toList();
      expect(removes, hasLength(1));
      expect(removes.single.arguments['tag'], 'sync');
    });

    test('remove of an unknown tag stays silent', () async {
      BackgroundKeepAlive.instance.remove('sync');
      await Future<void>.delayed(Duration.zero);

      expect(calls, isEmpty);
    });

    test('remove during permission wait suppresses the push', () async {
      final gate = Completer<bool>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'notificationGranted') return gate.future;
            if (call.method == 'update') return updateResult;
            return null;
          });
      BackgroundKeepAlive.instance.update('sync', 'Sync');
      await Future<void>.delayed(Duration.zero);
      BackgroundKeepAlive.instance.remove('sync');
      gate.complete(true);
      await Future<void>.delayed(Duration.zero);

      expect(calls.where((c) => c.method == 'update'), isEmpty);
    });

    test('refused update clears cache so the next one retries', () async {
      updateResult = false;
      BackgroundKeepAlive.instance.update('sync', 'Sync');
      await Future<void>.delayed(Duration.zero);
      updateResult = true;
      BackgroundKeepAlive.instance.update('sync', 'Sync');
      await Future<void>.delayed(Duration.zero);

      expect(calls.where((c) => c.method == 'update'), hasLength(2));
    });
  });
}
