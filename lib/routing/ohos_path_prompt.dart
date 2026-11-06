import 'package:flutter/material.dart';
import 'package:venera_unified/foundation/path_prompt.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/routing/app_navigation.dart';

/// HarmonyOS NEXT has no `file_selector` implementation, so the experimental
/// build asks for an absolute path instead of opening a system picker. This
/// keeps archive import and export usable without an extra plugin.
Future<String?> showOhosPathPrompt({
  required String title,
  required String hint,
  String? initialValue,
}) async {
  final controller = TextEditingController(text: initialValue ?? '');
  try {
    return await showDialog<String>(
      context: appNavigation.rootContext,
      builder: (dialogContext) => AlertDialog(
        title: Text(title.tl),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (value) {
            final trimmed = value.trim();
            Navigator.of(dialogContext).pop(trimmed.isEmpty ? null : trimmed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              Navigator.of(dialogContext).pop(value.isEmpty ? null : value);
            },
            child: Text('OK'.tl),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

void registerOhosPathPrompt() {
  registerPathPromptHandler(showOhosPathPrompt);
}
