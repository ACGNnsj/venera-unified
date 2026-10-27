/// The supported range for the user UI font scale and for the composed
/// system × user text scale.
const double minTextScale = 0.85;
const double maxTextScale = 1.30;

/// Composes the user UI font scale with the system text scale and caps the
/// product, so a large system font size combined with the max app slider
/// cannot push text past what the fixed-height chrome is laid out for.
///
/// Ported from venera's AppTheme.effectiveTextScale.
double effectiveTextScale(double systemScale, double userScale) {
  return (systemScale * userScale).clamp(minTextScale, maxTextScale);
}
