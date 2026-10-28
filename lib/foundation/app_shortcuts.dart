import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';

/// Desktop keyboard shortcut scopes. The system-wide (global) scope is
/// intentionally absent: unified already owns a complete global-hotkey stack
/// ([WindowHotkey] + controller + record UI) and this port does not rebuild
/// it. Cross conflicts between the two namespaces are unchecked in V1: the
/// system-level key wins deterministically, and the global hotkey is unbound
/// by default.
enum ShortcutScope {
  /// Anywhere in the app while the window has focus.
  app,

  /// Only while the reader is open.
  reader,
}

/// Desktop keyboard shortcuts the user can rebind. [title] is the English
/// source string; translate it with `.tl` at the call site.
///
/// Ported from VeneraX `shortcuts.dart` (4aa9c1a + ab1b011), minus
/// `toggleWindow` (existing global-hotkey stack, see [ShortcutScope]) and
/// `toggleNightMode` (unified has no reader night-mode toggle to execute).
/// First/last page stay hardcoded on Home/End and are not bindable.
enum ShortcutAction {
  toggleFullscreen(ShortcutScope.app, "Toggle fullscreen"),
  nextPage(ShortcutScope.reader, "Next page"),
  prevPage(ShortcutScope.reader, "Previous page"),
  nextChapter(ShortcutScope.reader, "Next Chapter"),
  prevChapter(ShortcutScope.reader, "Previous Chapter"),
  toggleReaderMenu(ShortcutScope.reader, "Show / hide reader menu"),
  toggleAutomaticReading(ShortcutScope.reader, "Automatic reading"),
  collectImage(ShortcutScope.reader, "Collect the image");

  const ShortcutAction(this.scope, this.title);

  final ShortcutScope scope;

  final String title;

  bool get isAvailable => App.isDesktop;
}

/// A non-modifier key plus the modifiers held with it.
@immutable
class KeyBinding {
  const KeyBinding(
    this.key, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  /// Reads the modifiers from [HardwareKeyboard], which is already up to date
  /// when the event is dispatched.
  factory KeyBinding.fromEvent(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    return KeyBinding(
      event.logicalKey,
      control: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
  }

  /// `ctrl+shift+<keyId>`; the key id is stable across platforms and builds.
  String encode() => [
    if (control) 'ctrl',
    if (shift) 'shift',
    if (alt) 'alt',
    if (meta) 'meta',
    key.keyId.toString(),
  ].join('+');

  static KeyBinding? decode(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split('+');
    final keyId = int.tryParse(parts.last);
    if (keyId == null) return null;
    final modifiers = parts.sublist(0, parts.length - 1).toSet();
    const known = {'ctrl', 'shift', 'alt', 'meta'};
    if (!known.containsAll(modifiers)) return null;
    return KeyBinding(
      LogicalKeyboardKey.findKeyByKeyId(keyId) ?? LogicalKeyboardKey(keyId),
      control: modifiers.contains('ctrl'),
      shift: modifiers.contains('shift'),
      alt: modifiers.contains('alt'),
      meta: modifiers.contains('meta'),
    );
  }

  bool matches(KeyEvent event) => KeyBinding.fromEvent(event) == this;

  /// Combinations a text field never turns into input.
  bool get hasCommandModifier => control || alt || meta;

  bool get isFunctionKey =>
      key.keyId >= LogicalKeyboardKey.f1.keyId &&
      key.keyId <= LogicalKeyboardKey.f24.keyId;

  static final modifierKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
    LogicalKeyboardKey.fnLock,
  };

  String get label {
    final name = keyLabel(key);
    if (App.isMacOS) {
      return [
        if (control) '⌃',
        if (alt) '⌥',
        if (shift) '⇧',
        if (meta) '⌘',
        name,
      ].join();
    }
    return [
      if (control) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) App.isLinux ? 'Super' : 'Win',
      name,
    ].join(' + ');
  }

  static String keyLabel(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'Space';
    // [decode] can produce keys with out-of-range ids; Flutter's getter
    // throws RangeError on those instead of returning '' (upstream has the
    // same latent crash), so fall back to hex here.
    String label;
    try {
      label = key.keyLabel;
    } catch (_) {
      label = '';
    }
    if (label.isEmpty) {
      return '0x${key.keyId.toRadixString(16)}';
    }
    return label.length == 1 ? label.toUpperCase() : label;
  }

  @override
  bool operator ==(Object other) =>
      other is KeyBinding &&
      other.key == key &&
      other.control == control &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, control, shift, alt, meta);
}

/// Bindings live in `keyboardShortcuts` as overrides only: action name →
/// encoded binding, '' for unbound. Anything absent follows [defaultBinding].
class AppShortcuts {
  AppShortcuts._();

  static const settingKey = 'keyboardShortcuts';

  /// Set while the binding editor records a key, so nothing fires meanwhile.
  static bool suspended = false;

  static KeyBinding? defaultBinding(ShortcutAction action) => switch (action) {
    ShortcutAction.toggleFullscreen =>
      App.isMacOS
          ? const KeyBinding(LogicalKeyboardKey.keyF, control: true, meta: true)
          : const KeyBinding(LogicalKeyboardKey.f11),
    ShortcutAction.nextPage => const KeyBinding(LogicalKeyboardKey.space),
    ShortcutAction.prevPage => const KeyBinding(
      LogicalKeyboardKey.space,
      shift: true,
    ),
    ShortcutAction.nextChapter => const KeyBinding(
      LogicalKeyboardKey.bracketRight,
    ),
    ShortcutAction.prevChapter => const KeyBinding(
      LogicalKeyboardKey.bracketLeft,
    ),
    ShortcutAction.toggleReaderMenu => const KeyBinding(
      LogicalKeyboardKey.enter,
    ),
    // Unbound by default: no safe universal combo, user picks one.
    ShortcutAction.toggleAutomaticReading ||
    ShortcutAction.collectImage => null,
  };

  static Map _stored() {
    final value = appdata.settings[settingKey];
    return value is Map ? value : const {};
  }

  static KeyBinding? bindingOf(ShortcutAction action) {
    final stored = _stored()[action.name];
    if (stored is! String) return defaultBinding(action);
    if (stored.isEmpty) return null;
    return KeyBinding.decode(stored) ?? defaultBinding(action);
  }

  static bool isCustomized(ShortcutAction action) =>
      _stored().containsKey(action.name);

  /// Null unbinds. Async: follows the unified write path
  /// ([updateSettings], sync off, this key is device-only).
  static Future<void> setBinding(ShortcutAction action, KeyBinding? binding) {
    final overrides = Map<String, dynamic>.from(_stored());
    if (binding == defaultBinding(action)) {
      overrides.remove(action.name);
    } else {
      overrides[action.name] = binding?.encode() ?? '';
    }
    return appdata.updateSettings((draft) {
      draft[settingKey] = overrides;
    }, sync: false);
  }

  static Future<void> resetAll() {
    return appdata.updateSettings((draft) {
      draft[settingKey] = <String, dynamic>{};
    }, sync: false);
  }

  /// Every binding shares one namespace: app shortcuts also fire in the
  /// reader, so a reader binding must not shadow an app one.
  static ShortcutAction? conflictOf(
    KeyBinding binding, {
    ShortcutAction? except,
  }) {
    for (final action in ShortcutAction.values) {
      if (action == except || !action.isAvailable) continue;
      if (bindingOf(action) == binding) return action;
    }
    return null;
  }

  /// Why [binding] can't be used for [action], as an English source string to
  /// translate, or null when it's fine. Conflicts are checked separately.
  /// Reservation rules copied from ab1b011 verbatim.
  static String? validate(ShortcutAction action, KeyBinding binding) {
    final key = binding.key;
    // Esc backs out of pages and dialogs, Tab moves focus, Alt+F4 closes the
    // window; none of them may be taken over.
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.tab ||
        (binding.alt && key == LogicalKeyboardKey.f4) ||
        _isReservedCombination(binding)) {
      return "This shortcut is reserved";
    }
    return null;
  }

  // Undo, redo, cut, copy, paste and select all. The app-scope handler can't
  // keep these from a text field, so a binding would fire alongside them.
  static final _editingKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.keyA,
    LogicalKeyboardKey.keyC,
    LogicalKeyboardKey.keyV,
    LogicalKeyboardKey.keyX,
    LogicalKeyboardKey.keyZ,
    LogicalKeyboardKey.keyY,
  };

  // macOS quit, close window, hide and minimize.
  static final _macAppKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.keyQ,
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyH,
    LogicalKeyboardKey.keyM,
  };

  static bool _isReservedCombination(KeyBinding b) =>
      isReservedCombination(b, macOS: App.isMacOS);

  /// Pure core of [_isReservedCombination]: [App] reads `dart:io`
  /// [Platform], which tests can't override, so the platform goes in as an
  /// explicit flag and both branches stay covered on any host.
  static bool isReservedCombination(KeyBinding b, {required bool macOS}) {
    // Ctrl on Windows / Linux, Cmd on macOS, with or without Shift (redo,
    // plain-text paste).
    final primary = macOS ? b.meta : b.control;
    final other = macOS ? b.control : b.meta;
    if (primary && !other && !b.alt && _editingKeys.contains(b.key)) {
      return true;
    }
    return macOS &&
        b.meta &&
        !b.control &&
        !b.alt &&
        !b.shift &&
        _macAppKeys.contains(b.key);
  }

  /// The action bound to [event] among [scopes]. While a text field has
  /// focus only bindings that can't be typed fire, so Space or a letter
  /// still reaches the field.
  static ShortcutAction? match(KeyEvent event, Set<ShortcutScope> scopes) {
    if (suspended || KeyBinding.modifierKeys.contains(event.logicalKey)) {
      return null;
    }
    final pressed = KeyBinding.fromEvent(event);
    for (final action in ShortcutAction.values) {
      if (!scopes.contains(action.scope) || !action.isAvailable) continue;
      if (bindingOf(action) != pressed) continue;
      if (!pressed.hasCommandModifier &&
          !pressed.isFunctionKey &&
          _isEditingText()) {
        return null;
      }
      return action;
    }
    return null;
  }

  static bool _isEditingText() {
    final focus = FocusManager.instance.primaryFocus?.context;
    return focus?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// [text] followed by the action's key, for tooltips and menu entries.
  static String hint(String text, ShortcutAction action) {
    if (!App.isDesktop) return text;
    final binding = bindingOf(action);
    return binding == null ? text : '$text (${binding.label})';
  }

  static bool _installed = false;

  /// App-scope shortcuts. Goes through [HardwareKeyboard] rather than the
  /// focus tree, so it works whatever has focus, and runs once per process.
  /// The fullscreen callback is injected: foundation stays UI-free, the
  /// executor lives next to the window frame.
  static void install({required Future<void> Function() onToggleFullscreen}) {
    if (!App.isDesktop || _installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler((event) {
      if (event is KeyUpEvent) return false;
      final action = match(event, const {ShortcutScope.app});
      if (action == null) return false;
      if (event is KeyDownEvent && action == ShortcutAction.toggleFullscreen) {
        onToggleFullscreen();
      }
      return true;
    });
  }
}
