import 'dart:convert';

class ChangelogSection {
  ChangelogSection(this.title, Iterable<String> lines)
    : lines = List.unmodifiable(lines);

  final String title;
  final List<String> lines;

  bool get isUnreleased => const {
    'unreleased',
    '\u672a\u53d1\u5e03',
    '\u672a\u767c\u5e03',
  }.contains(title.toLowerCase());
}

/// Index the document once. Widgets only consume the selected section's lines.
List<ChangelogSection> parseChangelog(String document) {
  final sections = <ChangelogSection>[];
  final heading = RegExp(r'^##[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$');
  final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})');
  String? title;
  var lines = <String>[];
  String? fenceMarker;

  void finish() {
    var start = 0;
    var end = lines.length;
    while (start < end && lines[start].trim().isEmpty) {
      start++;
    }
    while (end > start && lines[end - 1].trim().isEmpty) {
      end--;
    }
    if (title != null && start < end) {
      sections.add(ChangelogSection(title, lines.getRange(start, end)));
    }
  }

  for (final line in const LineSplitter().convert(
    document.replaceFirst(RegExp(r'^\uFEFF'), ''),
  )) {
    final marker = fence.firstMatch(line)?.group(1);
    if (marker != null) {
      if (fenceMarker == null) {
        fenceMarker = marker;
      } else if (marker[0] == fenceMarker[0] &&
          marker.length >= fenceMarker.length) {
        fenceMarker = null;
      }
      lines.add(line);
      continue;
    }
    final match = fenceMarker == null ? heading.firstMatch(line) : null;
    if (match == null) {
      lines.add(line);
      continue;
    }
    finish();
    title = match.group(1)!.trim();
    lines = [];
  }
  finish();
  if (title == null && lines.any((line) => line.trim().isNotEmpty)) {
    sections.add(ChangelogSection('Changelog', lines));
  }
  return List.unmodifiable(sections);
}
