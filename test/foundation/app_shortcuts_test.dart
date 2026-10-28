import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/app_shortcuts.dart';
import 'package:venera_unified/foundation/appdata.dart';

void _setOverrides(Map<String, dynamic> overrides) {
  appdata.settings[AppShortcuts.settingKey] = overrides;
}

// NOTE: unified [App] reads dart:io Platform, which tests can't override
// (upstream VeneraX used defaultTargetPlatform). Platform-dependent branches
// are covered through the pure [AppShortcuts.isReservedCombination] core and
// host-aware expectations below, so the suite is green on any desktop host.

void main() {
  tearDown(() {
    _setOverrides({});
    AppShortcuts.suspended = false;
  });

  test('a binding survives encode and decode', () {
    const binding = KeyBinding(
      LogicalKeyboardKey.keyH,
      control: true,
      alt: true,
      meta: true,
    );
    expect(KeyBinding.decode(binding.encode()), binding);
    const plain = KeyBinding(LogicalKeyboardKey.f11);
    expect(KeyBinding.decode(plain.encode()), plain);
  });

  test('decode rejects empty and malformed values', () {
    expect(KeyBinding.decode(null), isNull);
    expect(KeyBinding.decode(''), isNull);
    expect(KeyBinding.decode('ctrl+'), isNull);
    expect(KeyBinding.decode('hyper+97'), isNull);
  });

  test('default bindings never collide on this host', () {
    final seen = <KeyBinding, ShortcutAction>{};
    for (final action in ShortcutAction.values) {
      if (!action.isAvailable) continue;
      final binding = AppShortcuts.bindingOf(action);
      if (binding == null) continue;
      expect(
        seen[binding],
        isNull,
        reason: '${action.name} vs ${seen[binding]?.name}',
      );
      seen[binding] = action;
      expect(AppShortcuts.validate(action, binding), isNull);
    }
  });

  test('overrides replace, unbind, or fall back to the default', () {
    const custom = KeyBinding(LogicalKeyboardKey.keyF, control: true);
    _setOverrides({
      'toggleFullscreen': custom.encode(),
      'nextPage': '',
      'prevPage': 'garbage',
    });
    expect(AppShortcuts.bindingOf(ShortcutAction.toggleFullscreen), custom);
    expect(AppShortcuts.bindingOf(ShortcutAction.nextPage), isNull);
    expect(
      AppShortcuts.bindingOf(ShortcutAction.prevPage),
      AppShortcuts.defaultBinding(ShortcutAction.prevPage),
    );
    expect(AppShortcuts.isCustomized(ShortcutAction.nextPage), isTrue);
    expect(AppShortcuts.isCustomized(ShortcutAction.nextChapter), isFalse);
  });

  test('conflicts are found across scopes and skip the edited action', () {
    final f11 = AppShortcuts.defaultBinding(ShortcutAction.toggleFullscreen)!;
    expect(AppShortcuts.conflictOf(f11), ShortcutAction.toggleFullscreen);
    expect(
      AppShortcuts.conflictOf(f11, except: ShortcutAction.toggleFullscreen),
      isNull,
    );
    // An unbound action frees its key for others.
    _setOverrides({'toggleFullscreen': ''});
    expect(AppShortcuts.conflictOf(f11), isNull);
  });

  test('validation guards reserved keys', () {
    const fullscreen = ShortcutAction.toggleFullscreen;
    expect(
      AppShortcuts.validate(
        fullscreen,
        const KeyBinding(LogicalKeyboardKey.escape),
      ),
      isNotNull,
    );
    expect(
      AppShortcuts.validate(
        fullscreen,
        const KeyBinding(LogicalKeyboardKey.tab),
      ),
      isNotNull,
    );
    expect(
      AppShortcuts.validate(
        fullscreen,
        const KeyBinding(LogicalKeyboardKey.f4, alt: true),
      ),
      isNotNull,
    );
    // Text editing keeps its combinations (host modifier).
    final editing = App.isMacOS
        ? const KeyBinding(LogicalKeyboardKey.keyC, meta: true)
        : const KeyBinding(LogicalKeyboardKey.keyC, control: true);
    expect(AppShortcuts.validate(fullscreen, editing), isNotNull);
    expect(
      AppShortcuts.validate(
        fullscreen,
        App.isMacOS
            ? const KeyBinding(LogicalKeyboardKey.keyZ, meta: true, shift: true)
            : const KeyBinding(
                LogicalKeyboardKey.keyZ,
                control: true,
                shift: true,
              ),
      ),
      isNotNull,
    );
    // An extra modifier takes it out of the text-field namespace.
    expect(
      AppShortcuts.validate(
        fullscreen,
        const KeyBinding(LogicalKeyboardKey.keyC, control: true, alt: true),
      ),
      isNull,
    );
  });

  test('reserved combinations cover both platform cores', () {
    bool reserved(KeyBinding b, {bool macOS = false}) =>
        AppShortcuts.isReservedCombination(b, macOS: macOS);
    // Windows / Linux core: Ctrl (+Shift) editing keys.
    expect(
      reserved(const KeyBinding(LogicalKeyboardKey.keyC, control: true)),
      isTrue,
    );
    expect(
      reserved(
        const KeyBinding(LogicalKeyboardKey.keyZ, control: true, shift: true),
      ),
      isTrue,
    );
    expect(
      reserved(
        const KeyBinding(LogicalKeyboardKey.keyC, control: true, alt: true),
      ),
      isFalse,
    );
    // Ctrl+Q is not reserved outside macOS.
    expect(
      reserved(
        const KeyBinding(LogicalKeyboardKey.keyQ, control: true),
        macOS: false,
      ),
      isFalse,
    );
    // macOS core: Cmd editing and app combinations.
    for (final key in [
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyQ,
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.keyM,
    ]) {
      expect(
        reserved(KeyBinding(key, meta: true), macOS: true),
        isTrue,
        reason: key.keyLabel,
      );
    }
    // Ctrl is not the editing modifier there.
    expect(
      reserved(
        const KeyBinding(LogicalKeyboardKey.keyC, control: true),
        macOS: true,
      ),
      isFalse,
    );
    // Ctrl+Cmd+F, the macOS default, stays usable.
    expect(
      reserved(
        const KeyBinding(LogicalKeyboardKey.keyF, control: true, meta: true),
        macOS: true,
      ),
      isFalse,
    );
    // ... and the shipped validate() agrees with the core on this host.
    expect(
      AppShortcuts.validate(
            ShortcutAction.toggleFullscreen,
            const KeyBinding(LogicalKeyboardKey.keyC, control: true),
          ) !=
          null,
      reserved(
        const KeyBinding(LogicalKeyboardKey.keyC, control: true),
        macOS: App.isMacOS,
      ),
    );
  });

  test('key labels and host binding label', () {
    expect(KeyBinding.keyLabel(LogicalKeyboardKey.space), 'Space');
    expect(
      KeyBinding.keyLabel(const LogicalKeyboardKey(0x00ffffff)),
      '0xffffff',
    );
    expect(KeyBinding.keyLabel(LogicalKeyboardKey.keyF), 'F');
    const binding = KeyBinding(
      LogicalKeyboardKey.keyF,
      control: true,
      shift: true,
    );
    expect(
      binding.label,
      App.isMacOS
          ? '⌃⇧F'
          : App.isLinux
          ? 'Ctrl + Shift + F'
          : 'Ctrl + Shift + F',
    );
    expect(const KeyBinding(LogicalKeyboardKey.space).label, 'Space');
    if (!App.isMacOS) {
      expect(
        const KeyBinding(LogicalKeyboardKey.keyF, meta: true).label,
        App.isLinux ? 'Super + F' : 'Win + F',
      );
    }
  });

  group('async persistence', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('app-shortcuts-');
      App.dataPath = root.path;
      appdata.settings['disableSyncFields'] = '';
    });

    tearDown(() async {
      await appdata.restoreSettingsFields({
        AppShortcuts.settingKey: <String, dynamic>{},
      }, persist: false);
      root.deleteSync(recursive: true);
    });

    test('setBinding stores overrides and drops defaults', () async {
      const custom = KeyBinding(LogicalKeyboardKey.keyF, control: true);
      await AppShortcuts.setBinding(ShortcutAction.nextPage, custom);
      expect(AppShortcuts.bindingOf(ShortcutAction.nextPage), custom);
      expect(AppShortcuts.isCustomized(ShortcutAction.nextPage), isTrue);

      await AppShortcuts.setBinding(
        ShortcutAction.nextPage,
        AppShortcuts.defaultBinding(ShortcutAction.nextPage),
      );
      expect(AppShortcuts.isCustomized(ShortcutAction.nextPage), isFalse);
      expect(
        AppShortcuts.bindingOf(ShortcutAction.nextPage),
        AppShortcuts.defaultBinding(ShortcutAction.nextPage),
      );
    });

    test('setBinding null unbinds and resetAll clears everything', () async {
      await AppShortcuts.setBinding(ShortcutAction.nextPage, null);
      expect(AppShortcuts.bindingOf(ShortcutAction.nextPage), isNull);
      expect(AppShortcuts.isCustomized(ShortcutAction.nextPage), isTrue);

      await AppShortcuts.resetAll();
      expect(AppShortcuts.isCustomized(ShortcutAction.nextPage), isFalse);
      expect(
        AppShortcuts.bindingOf(ShortcutAction.nextPage),
        AppShortcuts.defaultBinding(ShortcutAction.nextPage),
      );
    });
  });

  group('matching key events', () {
    final matched = <ShortcutAction?>[];
    bool record(KeyEvent event) {
      if (event is KeyDownEvent) {
        matched.add(
          AppShortcuts.match(event, const {
            ShortcutScope.app,
            ShortcutScope.reader,
          }),
        );
      }
      return false;
    }

    setUp(() {
      matched.clear();
      HardwareKeyboard.instance.addHandler(record);
    });
    tearDown(() => HardwareKeyboard.instance.removeHandler(record));

    testWidgets(
      'modifiers pick the action',
      (tester) async {
        await tester.pumpWidget(
          const Focus(autofocus: true, child: SizedBox()),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
        expect(matched, [
          ShortcutAction.nextPage,
          null, // the Shift key itself
          ShortcutAction.prevPage,
          null,
        ]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'a focused text field keeps typed keys',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: Material(child: TextField(autofocus: true))),
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        expect(matched, [null, ShortcutAction.toggleFullscreen]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'nothing fires while the editor records',
      (tester) async {
        await tester.pumpWidget(
          const Focus(autofocus: true, child: SizedBox()),
        );
        AppShortcuts.suspended = true;
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        expect(matched, [null]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });
}
