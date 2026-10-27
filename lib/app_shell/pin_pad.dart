import 'package:flutter/material.dart';
import 'package:venera_unified/foundation/translations.dart';

/// 四位数字 PIN 输入盘。
///
/// 输入满 [length] 位就回调一次 [onSubmitted]；[error] 非空时清空输入并显示提示，
/// 由调用方在异步校验失败后塞进来。
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.onSubmitted,
    this.length = 4,
    this.error,
  });

  final void Function(String pin) onSubmitted;
  final int length;
  final String? error;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _input = '';

  @override
  void didUpdateWidget(covariant PinPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.error != null && widget.error != oldWidget.error) {
      _input = '';
    }
  }

  void _append(String digit) {
    if (_input.length >= widget.length) return;
    setState(() => _input += digit);
    if (_input.length == widget.length) {
      final pin = _input;
      widget.onSubmitted(pin);
    }
  }

  void _backspace() {
    if (_input.isEmpty) return;
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < widget.length; i++)
              Container(
                key: ValueKey('pin-dot-$i'),
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _input.length
                      ? scheme.primary
                      : scheme.primary.withValues(alpha: 0.2),
                ),
              ),
          ],
        ),
        if (widget.error != null) ...[
          const SizedBox(height: 12),
          Text(widget.error!, style: TextStyle(color: scheme.error)),
        ],
        const SizedBox(height: 20),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
          ['', '0', '<'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final label in row)
                SizedBox(
                  width: 72,
                  height: 64,
                  child: label.isEmpty
                      ? null
                      : TextButton(
                          onPressed: label == '<'
                              ? _backspace
                              : () => _append(label),
                          child: Text(
                            label == '<' ? '⌫' : label,
                            style: const TextStyle(fontSize: 22),
                          ),
                        ),
                ),
            ],
          ),
      ],
    );
  }
}

/// 设置页、认证页共用的「清除 / 保存」提示文案。
String get pinMismatchMessage => 'PIN does not match'.tl;
