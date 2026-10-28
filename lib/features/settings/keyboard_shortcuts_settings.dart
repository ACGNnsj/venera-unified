import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/components/settings_save_state.dart';
import 'package:venera_unified/foundation/app_shortcuts.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

/// Desktop shortcut bindings. Tap a row to record a new combination.
///
/// Ported from VeneraX `keyboard_shortcuts_settings.dart` (4aa9c1a), minus
/// the global-hotkey row (unified owns that stack separately, see
/// [ShortcutScope]) and with writes going through [SettingsSaveState].
class KeyboardShortcutsSettings extends StatefulWidget {
  const KeyboardShortcutsSettings({super.key});

  @override
  State<KeyboardShortcutsSettings> createState() =>
      _KeyboardShortcutsSettingsState();
}

class _KeyboardShortcutsSettingsState
    extends SettingsSaveState<KeyboardShortcutsSettings> {
  Future<void> _edit(ShortcutAction action) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => _ShortcutRecorderDialog(action: action),
    );
    if (changed != true || !mounted) return;
    setState(() {});
  }

  Future<void> _resetAll() async {
    if (!acceptsSettingsChanges || savingSettings || hasSettingsSaveError) {
      return;
    }
    await saveSetting(
      const ('shortcuts', 'all'),
      AppShortcuts.resetAll,
      onSaved: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final actions = ShortcutAction.values.where((a) => a.isAvailable);
    return protectSettings(
      Scaffold(
        appBar: Appbar(
          title: Text("Keyboard shortcuts".tl),
          actions: [
            Tooltip(
              message: "Reset to Default".tl,
              child: IconButton(
                icon: const Icon(Icons.restart_alt),
                onPressed: _resetAll,
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            _ShortcutGroupHeader("General".tl),
            for (final a in actions.where(
              (a) => a.scope != ShortcutScope.reader,
            ))
              _buildTile(a),
            _ShortcutGroupHeader("Reader".tl),
            for (final a in actions.where(
              (a) => a.scope == ShortcutScope.reader,
            ))
              _buildTile(a),
            Text(
              "Arrow keys turn pages in the reading direction; Esc leaves the reader."
                  .tl,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ).paddingHorizontal(16).paddingTop(8),
            if (savingSettings || hasSettingsSaveError) settingsSaveStatus,
          ],
        ),
      ),
    );
  }

  Widget _buildTile(ShortcutAction action) {
    final binding = AppShortcuts.bindingOf(action);
    return ListTile(
      title: Text(action.title.tl),
      trailing: binding == null
          ? Text(
              "Not set".tl,
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            )
          : _KeyCap(binding.label),
      onTap: () => _edit(action),
    );
  }
}

class _ShortcutGroupHeader extends StatelessWidget {
  const _ShortcutGroupHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ).paddingHorizontal(16).paddingTop(16).paddingBottom(4);
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}

/// Records one combination for [action]. Pops true once the binding changed.
class _ShortcutRecorderDialog extends StatefulWidget {
  const _ShortcutRecorderDialog({required this.action});

  final ShortcutAction action;

  @override
  State<_ShortcutRecorderDialog> createState() =>
      _ShortcutRecorderDialogState();
}

class _ShortcutRecorderDialogState
    extends SettingsSaveState<_ShortcutRecorderDialog> {
  final _focusNode = FocusNode();

  /// The last combination pressed, shown in place of the current binding.
  KeyBinding? _pressed;

  String? _error;

  bool _done = false;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Nothing may fire while recording.
    AppShortcuts.suspended = true;
  }

  @override
  void dispose() {
    // Cancel / Esc / the close button; _finish has already resumed otherwise.
    if (!_done) AppShortcuts.suspended = false;
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _finish(KeyBinding? binding) async {
    if (_done || _saving) return;
    _saving = true;
    try {
      final action = widget.action;
      final accepted = await saveSetting((
        'shortcuts',
        action.name,
      ), () => AppShortcuts.setBinding(action, binding));
      // Refused or failed: stay open and keep recording.
      if (!accepted || !mounted) return;
      _done = true;
      AppShortcuts.suspended = false;
      if (mounted) context.pop(true);
    } finally {
      _saving = false;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_done) return KeyEventResult.handled;
    // Let Esc close the dialog.
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent ||
        savingSettings ||
        hasSettingsSaveError ||
        KeyBinding.modifierKeys.contains(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    final binding = KeyBinding.fromEvent(event);
    var error = AppShortcuts.validate(widget.action, binding)?.tl;
    if (error == null) {
      final other = AppShortcuts.conflictOf(binding, except: widget.action);
      if (other != null) {
        error = "Already used by @a".tlParams({'a': other.title.tl});
      }
    }
    if (error == null) {
      _finish(binding);
    } else {
      setState(() {
        _pressed = binding;
        _error = error;
      });
    }
    return KeyEventResult.handled;
  }

  void _resetToDefault() {
    final binding = AppShortcuts.defaultBinding(widget.action);
    final other = binding == null
        ? null
        : AppShortcuts.conflictOf(binding, except: widget.action);
    if (other != null) {
      setState(() {
        _pressed = binding;
        _error = "Already used by @a".tlParams({'a': other.title.tl});
      });
      return;
    }
    _finish(binding);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _pressed ?? AppShortcuts.bindingOf(widget.action);
    final enabled =
        acceptsSettingsChanges && !savingSettings && !hasSettingsSaveError;
    return protectSettings(
      AlertDialog(
        title: Text(widget.action.title.tl),
        scrollable: true,
        content: SizedBox(
          width: 360,
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _onKey,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _focusNode.requestFocus,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Press the new key combination".tl,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    if (shown == null)
                      Text(
                        "Not set".tl,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      )
                    else
                      _KeyCap(shown.label),
                    const SizedBox(height: 12),
                    Text(
                      _error ?? '',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    if (savingSettings || hasSettingsSaveError)
                      settingsSaveStatus,
                  ],
                ).paddingVertical(8),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: enabled ? () => _finish(null) : null,
            child: Text("Clear".tl),
          ),
          TextButton(
            onPressed: enabled ? _resetToDefault : null,
            child: Text("Reset to Default".tl),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: savingSettings ? null : () => leaveSettings(),
            child: Text("Cancel".tl),
          ),
        ],
      ),
    );
  }
}
