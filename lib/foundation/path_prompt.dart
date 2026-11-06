import 'dart:async';

/// Asks the user for an absolute path when the platform has no file picker.
typedef PathPromptHandler =
    Future<String?> Function({
      required String title,
      required String hint,
      String? initialValue,
    });

PathPromptHandler? _handler;

/// Registered once by the UI layer at startup. Platform fallbacks in
/// `foundation/` cannot import `components/` or `routing/`, so the dialog
/// implementation is injected instead of imported.
void registerPathPromptHandler(PathPromptHandler handler) {
  _handler = handler;
}

/// Returns `null` when no handler is registered (headless runs, tests) or when
/// the user dismisses the prompt.
Future<String?> promptPathInput({
  required String title,
  required String hint,
  String? initialValue,
}) async {
  final handler = _handler;
  if (handler == null) return null;
  return handler(title: title, hint: hint, initialValue: initialValue);
}
