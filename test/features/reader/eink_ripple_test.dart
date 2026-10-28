import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/reader/eink_ripple.dart';
import 'package:venera_unified/features/reader/images_host.dart';
import 'package:venera_unified/features/reader/reader_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('venera/eink');

  setUp(() {
    EinkPanel.debugReset();
    EinkPanel.debugSupported = true;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    EinkPanel.debugReset();
    EinkPanel.debugSupported = null;
  });

  test('gallery turns map to the way the page content moves', () {
    const cases = {
      (ReaderMode.galleryLeftToRight, true): RippleSweep.leftward,
      (ReaderMode.galleryLeftToRight, false): RippleSweep.rightward,
      (ReaderMode.galleryRightToLeft, true): RippleSweep.rightward,
      (ReaderMode.galleryRightToLeft, false): RippleSweep.leftward,
      (ReaderMode.galleryTopToBottom, true): RippleSweep.upward,
      (ReaderMode.galleryTopToBottom, false): RippleSweep.downward,
    };
    cases.forEach((input, sweep) {
      expect(
        galleryRippleSweep(input.$1, forward: input.$2),
        sweep,
        reason: '$input',
      );
    });
  });

  test('continuous modes have no ripple', () {
    for (final mode in ReaderMode.values.where((m) => m.isContinuous)) {
      expect(galleryRippleSweep(mode, forward: true), isNull);
    }
  });

  test('next-page turns arm the controller codes per reading direction', () {
    List<int> codesFor(ReaderMode mode) => rippleCodes(
      galleryRippleSweep(mode, forward: true)!,
      RippleSpeed.standard,
    );
    // Values match the upstream VeneraX vectors (rotation index 0-3).
    expect(codesFor(ReaderMode.galleryLeftToRight), [65, 68, 66, 67]);
    expect(codesFor(ReaderMode.galleryRightToLeft), [66, 67, 65, 68]);
    expect(codesFor(ReaderMode.galleryTopToBottom), [68, 66, 67, 65]);
  });

  test('speed flags ride alongside the direction codes', () {
    expect(rippleCodes(RippleSweep.leftward, RippleSpeed.faster), [1, 4, 2, 3]);
    expect(rippleCodes(RippleSweep.leftward, RippleSpeed.slower), [
      129,
      132,
      130,
      131,
    ]);
  });

  test('probe caches the native support flag', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          expect(call.method, 'rippleSupported');
          return true;
        });

    expect(EinkPanel.rippleProbed, isFalse);
    expect(await EinkPanel.probeRipple(), isTrue);
    expect(EinkPanel.rippleSupported, isTrue);
    // Second probe reuses the cache; native is hit once.
    expect(await EinkPanel.probeRipple(), isTrue);
    expect(calls, 1);
  });

  test('queueRipple sends the rotation code vector', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });

    expect(await EinkPanel.probeRipple(), isTrue);
    await EinkPanel.queueRipple(
      RippleSweep.leftward,
      speed: RippleSpeed.standard,
    );

    final ripple = calls.where((c) => c.method == 'queueRipple').toList();
    expect(ripple, hasLength(1));
    expect(ripple.single.arguments, [65, 68, 66, 67]);
  });

  test('queueRipple is silent before a positive probe', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          return false;
        });

    expect(await EinkPanel.probeRipple(), isFalse);
    await EinkPanel.queueRipple(
      RippleSweep.leftward,
      speed: RippleSpeed.standard,
    );
    // Only the probe went out; the ripple was skipped.
    expect(calls, 1);
  });

  test('probe never touches the channel off Android', () async {
    EinkPanel.debugSupported = false;
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          return true;
        });

    expect(await EinkPanel.probeRipple(), isFalse);
    expect(calls, 0);
  });
}
