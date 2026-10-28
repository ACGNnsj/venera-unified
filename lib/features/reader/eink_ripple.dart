import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/log.dart';

/// Direction the page content travels during a turn, as the reader sees it.
/// Declared clockwise from up; [rippleCodes] and [opposite] rely on the order.
enum RippleSweep {
  upward,
  rightward,
  downward,
  leftward;

  RippleSweep get opposite => values[(index + 2) % 4];
}

enum RippleSpeed {
  slower('slower', 128),
  standard('standard', 64),
  faster('faster', 0);

  const RippleSpeed(this.key, this.flag);

  final String key;

  /// Speed bits the display controller reads alongside the direction.
  final int flag;

  static RippleSpeed fromKey(Object? key) =>
      values.firstWhere((e) => e.key == key, orElse: () => standard);
}

/// The controller names directions by the panel's own edges, which only line
/// up with the reader's view in the natural orientation. Index i of the result
/// is the command for display rotation i (quarter turns), picked natively.
@visibleForTesting
List<int> rippleCodes(RippleSweep sweep, RippleSpeed speed) {
  // Panel edge codes, clockwise from the top edge.
  const edgeCodes = [4, 2, 3, 1];
  return [
    for (var rotation = 0; rotation < 4; rotation++)
      edgeCodes[(sweep.index + rotation) % 4] | speed.flag,
  ];
}

/// Native page-turn ripple on supported e-readers (Android only).
class EinkPanel {
  EinkPanel._();

  static const _channel = MethodChannel('venera/eink');

  static bool? _supported;

  static Future<bool>? _probe;

  /// Last probe result; false until [probeRipple] completes.
  static bool get rippleSupported => _supported == true;

  static bool get rippleProbed => _supported != null;

  /// Forces the platform gate in tests; the test VM is never Android.
  static bool? _debugSupported;

  /// Sets [_debugSupported]; call with null to restore platform behavior.
  @visibleForTesting
  static set debugSupported(bool? value) => _debugSupported = value;

  /// Clears the probe cache between tests.
  @visibleForTesting
  static void debugReset() {
    _supported = null;
    _probe = null;
  }

  static Future<bool> probeRipple() {
    return _probe ??= () async {
      var supported = false;
      if (_debugSupported ?? App.isAndroid) {
        try {
          supported =
              await _channel.invokeMethod<bool>('rippleSupported') == true;
        } catch (e) {
          Log.error("E-ink", "Ripple probe failed: $e");
        }
      }
      return _supported = supported;
    }();
  }

  /// Arms the ripple for the next screen update. Completes once the command is
  /// in place, so the caller can draw the new page right after.
  static Future<void> queueRipple(
    RippleSweep sweep, {
    required RippleSpeed speed,
  }) async {
    if (!rippleSupported) return;
    try {
      await _channel
          .invokeMethod('queueRipple', rippleCodes(sweep, speed))
          .timeout(const Duration(milliseconds: 300));
    } catch (e) {
      Log.error("E-ink", "Ripple command failed: $e");
    }
  }
}
