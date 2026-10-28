import 'package:flutter/material.dart';
import 'package:venera_unified/components/pattern_lock.dart';
import 'package:venera_unified/components/pin_pad.dart';
import 'package:venera_unified/components/select_dialog.dart';
import 'package:venera_unified/features/settings/pin_setup_dialog.dart';
import 'package:venera_unified/foundation/auth_storage.dart';
import 'package:venera_unified/foundation/translations.dart';

String appLockTypeName(AppLockType type) => switch (type) {
  AppLockType.biometric => 'Biometric'.tl,
  AppLockType.pin => 'PIN'.tl,
  AppLockType.password => 'Password'.tl,
  AppLockType.pattern => 'Pattern'.tl,
};

/// 解锁方式管理总入口（设置页 "Unlock method" 入口调用）。
///
/// 先选方式；已有凭据时先按旧类型验旧，再按新类型走两遍确认写入。
/// 返回 true 表示凭据有写入或清除。
Future<bool> manageAppLockCredential(BuildContext context) async {
  final current = await AuthStorage.credentialType();
  if (!context.mounted) return false;
  final picked = await showUnlockMethodPicker(context, current: current);
  if (picked == null || !context.mounted) return false;
  if (picked == AppLockType.biometric) {
    // 移除：先验旧凭据再清。
    if (current != null && !await verifyCurrentCredential(context)) {
      return false;
    }
    if (!context.mounted) return false;
    await AuthStorage.writeCredential(AppLockType.biometric);
    return true;
  }
  if (picked == AppLockType.pin && current == AppLockType.pin) {
    // PIN 沿用旧对话框（含"输入当前 PIN"，行为零变)。
    return await PinSetupDialog.show(context, requiresCurrent: true) ?? false;
  }
  if (current != null) {
    if (!await verifyCurrentCredential(context)) return false;
    if (!context.mounted) return false;
  }
  switch (picked) {
    case AppLockType.pin:
      return await PinSetupDialog.show(context) ?? false;
    case AppLockType.password:
      return await PasswordSetupDialog.show(context) ?? false;
    case AppLockType.pattern:
      return await PatternSetupDialog.show(context) ?? false;
    case AppLockType.biometric:
      return false; // 不可达：移除分支前面已处理。
  }
}

/// 选择解锁方式。返回 [AppLockType.biometric] 表示"移除凭据"，
/// 返回 null 表示取消。
Future<AppLockType?> showUnlockMethodPicker(
  BuildContext context, {
  AppLockType? current,
}) async {
  const types = [AppLockType.pin, AppLockType.password, AppLockType.pattern];
  final options = [for (final t in types) appLockTypeName(t)];
  if (current != null) options.add('Remove lock'.tl);
  final index = await showSelectDialog(
    context: context,
    title: 'Unlock method'.tl,
    options: options,
    initialIndex: current == null ? null : types.indexOf(current),
  );
  if (index == null) return null;
  if (index >= types.length) return AppLockType.biometric;
  return types[index];
}

/// 按已存凭据的类型验旧；没有凭据时直接过。
Future<bool> verifyCurrentCredential(BuildContext context) async {
  final type = await AuthStorage.credentialType();
  if (type == null) return true;
  if (!context.mounted) return false;
  switch (type) {
    case AppLockType.pin:
      return await _VerifyPinDialog.show(context) ?? false;
    case AppLockType.password:
      return await _VerifyPasswordDialog.show(context) ?? false;
    case AppLockType.pattern:
      return await _VerifyPatternDialog.show(context) ?? false;
    case AppLockType.biometric:
      return true; // 不可达：credentialType() 永不返回 biometric。
  }
}

class _VerifyPinDialog extends StatefulWidget {
  const _VerifyPinDialog();

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => const _VerifyPinDialog(),
    );
  }

  @override
  State<_VerifyPinDialog> createState() => _VerifyPinDialogState();
}

class _VerifyPinDialogState extends State<_VerifyPinDialog> {
  String? _error;

  Future<void> _handle(String pin) async {
    if (await AuthStorage.verify(pin)) {
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } else {
      if (!mounted) return;
      setState(() => _error = 'PIN does not match'.tl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Enter current PIN'.tl),
      content: PinPad(error: _error, onSubmitted: _handle),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel'.tl),
        ),
      ],
    );
  }
}

class _VerifyPasswordDialog extends StatefulWidget {
  const _VerifyPasswordDialog();

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => const _VerifyPasswordDialog(),
    );
  }

  @override
  State<_VerifyPasswordDialog> createState() => _VerifyPasswordDialogState();
}

class _VerifyPasswordDialogState extends State<_VerifyPasswordDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (await AuthStorage.verify(_controller.text)) {
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } else {
      if (!mounted) return;
      setState(() => _error = 'Incorrect'.tl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Enter current password'.tl),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: true,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          errorText: _error,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel'.tl),
        ),
        TextButton(onPressed: _submit, child: Text('Confirm'.tl)),
      ],
    );
  }
}

class _VerifyPatternDialog extends StatefulWidget {
  const _VerifyPatternDialog();

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => const _VerifyPatternDialog(),
    );
  }

  @override
  State<_VerifyPatternDialog> createState() => _VerifyPatternDialogState();
}

class _VerifyPatternDialogState extends State<_VerifyPatternDialog> {
  bool _error = false;

  Future<void> _handle(List<int> pattern) async {
    if (await AuthStorage.verify(patternToString(pattern))) {
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } else {
      if (!mounted) return;
      setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Draw current pattern'.tl),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error ? 'Incorrect'.tl : 'Draw pattern to continue'.tl,
            style: TextStyle(
              color: _error ? Theme.of(context).colorScheme.error : null,
            ),
          ),
          const SizedBox(height: 16),
          PatternLock(size: 240, dimByDefault: _error, onComplete: _handle),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel'.tl),
        ),
      ],
    );
  }
}

/// 设置 / 更换文本密码的对话框（两次输入确认，流程照抄 VeneraX _setupCode）。
class PasswordSetupDialog extends StatefulWidget {
  const PasswordSetupDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => const PasswordSetupDialog(),
    );
  }

  @override
  State<PasswordSetupDialog> createState() => _PasswordSetupDialogState();
}

class _PasswordSetupDialogState extends State<PasswordSetupDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _first.text;
    if (value.isEmpty) {
      setState(() => _error = 'Cannot be empty'.tl);
      return;
    }
    if (value != _second.text) {
      setState(() => _error = 'Entries do not match'.tl);
      return;
    }
    await AuthStorage.writeCredential(AppLockType.password, value);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Widget _field(TextEditingController c, String hint, bool autofocus) {
    return TextField(
      controller: c,
      autofocus: autofocus,
      obscureText: true,
      decoration: InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
      onSubmitted: (_) => _submit(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Set Password'.tl),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _field(_first, 'Enter Password'.tl, true),
          const SizedBox(height: 12),
          _field(_second, 'Confirm'.tl, false),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel'.tl),
        ),
        TextButton(onPressed: _submit, child: Text('Confirm'.tl)),
      ],
    );
  }
}

/// 设置 / 更换手势图案的对话框（画两遍确认，流程照抄 VeneraX _setupPattern）。
class PatternSetupDialog extends StatefulWidget {
  const PatternSetupDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => const PatternSetupDialog(),
    );
  }

  @override
  State<PatternSetupDialog> createState() => _PatternSetupDialogState();
}

class _PatternSetupDialogState extends State<PatternSetupDialog> {
  List<int>? _firstPattern;
  String? _error;

  Future<void> _handle(List<int> pattern) async {
    if (pattern.length < 4) {
      setState(() => _error = 'Connect at least 4 dots'.tl);
      return;
    }
    if (_firstPattern == null) {
      setState(() {
        _firstPattern = pattern;
        _error = null;
      });
      return;
    }
    if (patternToString(pattern) != patternToString(_firstPattern!)) {
      setState(() {
        _firstPattern = null;
        _error = 'Patterns do not match'.tl;
      });
      return;
    }
    await AuthStorage.writeCredential(
      AppLockType.pattern,
      patternToString(pattern),
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Set Pattern'.tl),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error ??
                (_firstPattern == null
                    ? 'Draw an unlock pattern'.tl
                    : 'Draw again to confirm'.tl),
            style: TextStyle(
              color: _error != null
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          PatternLock(
            // 两遍之间重建，内部状态干净重置。
            key: ValueKey(_firstPattern == null),
            size: 240,
            onComplete: _handle,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel'.tl),
        ),
      ],
    );
  }
}
