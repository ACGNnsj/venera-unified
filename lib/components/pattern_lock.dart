import 'package:flutter/material.dart';

/// 3x3 手势图案输入（移植自 VeneraX `components/pattern_lock.dart`）。
///
/// 手指抬起时通过 [onComplete] 上报路径点序号（0-8，按行排列）。
/// 纯渲染组件：不存"正确图案"的概念，调用方把上报序列经 [patternToString]
/// 序列化后与已存凭据比对。
class PatternLock extends StatefulWidget {
  const PatternLock({
    super.key,
    required this.onComplete,
    this.size = 280,
    this.dimByDefault = false,
  });

  final void Function(List<int> pattern) onComplete;

  final double size;

  /// 为 true 时点与连线用错误色绘制（父组件用来提示不匹配）。
  final bool dimByDefault;

  @override
  State<PatternLock> createState() => _PatternLockState();
}

class _PatternLockState extends State<PatternLock> {
  final List<int> _selected = [];
  Offset? _currentPointer;

  static const _dots = 3;

  double get _cell => widget.size / _dots;

  Offset _dotCenter(int index) {
    var row = index ~/ _dots;
    var col = index % _dots;
    return Offset(_cell * col + _cell / 2, _cell * row + _cell / 2);
  }

  int? _hitDot(Offset pos) {
    for (var i = 0; i < _dots * _dots; i++) {
      if ((pos - _dotCenter(i)).distance < _cell * 0.3) {
        return i;
      }
    }
    return null;
  }

  void _addDot(Offset pos) {
    var dot = _hitDot(pos);
    if (dot != null && !_selected.contains(dot)) {
      // 自动带上上一个选中点与当前点连线正中穿过的点（标准 Android 图案行为）。
      if (_selected.isNotEmpty) {
        var last = _selected.last;
        var mid = _dotBetween(last, dot);
        if (mid != null && !_selected.contains(mid)) {
          _selected.add(mid);
        }
      }
      _selected.add(dot);
    }
  }

  /// [a] 与 [b] 正中间的点（如果有），例如 0->2 穿过 1，0->8 穿过 4。
  int? _dotBetween(int a, int b) {
    var ra = a ~/ _dots, ca = a % _dots;
    var rb = b ~/ _dots, cb = b % _dots;
    if ((ra + rb) % 2 != 0 || (ca + cb) % 2 != 0) return null;
    var mr = (ra + rb) ~/ 2, mc = (ca + cb) ~/ 2;
    return mr * _dots + mc;
  }

  void _onPanEnd() {
    if (_selected.isNotEmpty) {
      widget.onComplete(List.of(_selected));
    }
    setState(() {
      _selected.clear();
      _currentPointer = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var color = widget.dimByDefault ? scheme.error : scheme.primary;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: GestureDetector(
        onPanStart: (d) => setState(() {
          _selected.clear();
          _addDot(d.localPosition);
          _currentPointer = d.localPosition;
        }),
        onPanUpdate: (d) => setState(() {
          _addDot(d.localPosition);
          _currentPointer = d.localPosition;
        }),
        onPanEnd: (_) => _onPanEnd(),
        child: CustomPaint(
          painter: _PatternPainter(
            // 快照：_selected 是原地改的，传引用会让 shouldRepaint 的比对失效。
            selected: List.of(_selected),
            pointer: _currentPointer,
            dotCenter: _dotCenter,
            color: color,
            baseColor: scheme.outlineVariant,
          ),
        ),
      ),
    );
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter({
    required this.selected,
    required this.pointer,
    required this.dotCenter,
    required this.color,
    required this.baseColor,
  });

  final List<int> selected;
  final Offset? pointer;
  final Offset Function(int) dotCenter;
  final Color color;
  final Color baseColor;

  @override
  void paint(Canvas canvas, Size size) {
    var cell = size.width / 3;
    var dotRadius = cell * 0.08;
    var selectedRadius = cell * 0.14;

    var linePaint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // 按序连接已选点。
    for (var i = 0; i < selected.length - 1; i++) {
      canvas.drawLine(
        dotCenter(selected[i]),
        dotCenter(selected[i + 1]),
        linePaint,
      );
    }
    // 手指当前位置的拖尾线。
    if (selected.isNotEmpty && pointer != null) {
      canvas.drawLine(dotCenter(selected.last), pointer!, linePaint);
    }

    for (var i = 0; i < 9; i++) {
      var isSelected = selected.contains(i);
      var paint = Paint()
        ..color = isSelected ? color : baseColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        dotCenter(i),
        isSelected ? selectedRadius : dotRadius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) {
    if (old.pointer != pointer) return true;
    if (old.selected.length != selected.length) return true;
    for (var i = 0; i < selected.length; i++) {
      if (old.selected[i] != selected[i]) return true;
    }
    return false;
  }
}

/// 把图案序列化为稳定字符串，用于哈希与比对。
String patternToString(List<int> pattern) => pattern.join('-');
