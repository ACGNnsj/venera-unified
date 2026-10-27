import 'package:flutter/animation.dart';

/// Unified spacing tokens based on a 4px grid.
///
/// Use these instead of hardcoded EdgeInsets values.
///
/// Copied from venera's lib/foundation/app_theme.dart. New code should use
/// these tokens; existing call sites are migrated separately.
abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

/// Unified border radius tokens, following the Material 3 shape scale.
///
/// Use these instead of hardcoded BorderRadius.circular() values.
///
/// Copied from venera's lib/foundation/app_theme.dart. New code should use
/// these tokens; existing call sites are migrated separately.
abstract final class AppRadius {
  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;
  static const double xxl = 28;
  static const double full = 999;
}

/// Motion tokens from the Material 3 spec: durations by component size and
/// the emphasized easing family.
///
/// Use these instead of hardcoded Durations and ad-hoc Curves.
///
/// Copied from venera's lib/foundation/app_theme.dart. New code should use
/// these tokens; existing call sites are migrated separately.
abstract final class AppMotion {
  /// Small components (chips, buttons): 50-200ms. short4 = 200ms.
  static const Duration short = Duration(milliseconds: 200);

  /// Medium components (sheet, FAB): 250-400ms. medium2 = 300ms.
  static const Duration medium = Duration(milliseconds: 300);

  /// Large regions (page transitions): 450-600ms. long2 = 500ms.
  static const Duration long = Duration(milliseconds: 500);

  /// The M3 emphasized easing: starts slow, accelerates, settles slowly.
  /// Preferred for large on-screen motion (pages, panes).
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// A standard decelerating curve for elements entering the screen.
  static const Curve decelerate = Curves.easeOutCubic;
}
