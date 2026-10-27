import 'package:flutter/material.dart';
import 'package:venera_unified/app_shell/pin_pad.dart';
import 'package:venera_unified/foundation/auth_storage.dart';
import 'package:venera_unified/foundation/translations.dart';

/// 设置 / 更换应用内 PIN 的对话框。
///
/// 已经设置过 PIN 时先要求输入当前 PIN；输入新 PIN 后要点两次确认。
/// 关闭返回 true 表示 PIN 已被写入或清除。
class PinSetupDialog extends StatefulWidget {
  const PinSetupDialog({super.key, this.requiresCurrent = false});

  final bool requiresCurrent;

  static Future<bool?> show(
    BuildContext context, {
    bool requiresCurrent = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => PinSetupDialog(requiresCurrent: requiresCurrent),
    );
  }

  @override
  State<PinSetupDialog> createState() => _PinSetupDialogState();
}

enum _Stage { current, next, confirm }

class _PinSetupDialogState extends State<PinSetupDialog> {
  _Stage _stage = _Stage.current;
  String _first = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!widget.requiresCurrent) _stage = _Stage.next;
  }

  String get _title => switch (_stage) {
    _Stage.current => 'Enter current PIN'.tl,
    _Stage.next => 'Enter a 4-digit PIN'.tl,
    _Stage.confirm => 'Confirm PIN'.tl,
  };

  Future<void> _handle(String pin) async {
    switch (_stage) {
      case _Stage.current:
        if (await AuthStorage.verify(pin)) {
          if (!mounted) return;
          setState(() {
            _stage = _Stage.next;
            _error = null;
          });
        } else {
          if (!mounted) return;
          setState(() => _error = 'PIN does not match'.tl);
        }
      case _Stage.next:
        setState(() {
          _first = pin;
          _stage = _Stage.confirm;
          _error = null;
        });
      case _Stage.confirm:
        if (pin != _first) {
          setState(() {
            _error = 'PINs do not match'.tl;
            _first = '';
            _stage = _Stage.next;
          });
          return;
        }
        await AuthStorage.writePassword(pin);
        if (!mounted) return;
        Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_title),
      content: PinPad(error: _error, onSubmitted: _handle),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel'.tl),
        ),
        if (widget.requiresCurrent)
          TextButton(
            onPressed: () async {
              await AuthStorage.writePassword(null);
              if (!context.mounted) return;
              Navigator.of(context).pop(true);
            },
            child: Text('Clear PIN'.tl),
          ),
      ],
    );
  }
}
