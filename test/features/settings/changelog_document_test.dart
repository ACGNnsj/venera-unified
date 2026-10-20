import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/changelog_document.dart';

void main() {
  test('indexes versions in document order and omits empty sections', () {
    final sections = parseChangelog('''# Changelog
Project introduction.

## Unreleased

## v2.0.0
### Fixed
- First fix.

## v2.0.0-rc.1
- Candidate fix.

## v1.9.0
- Old fix.
''');
    expect(sections.map((section) => section.title), [
      'v2.0.0',
      'v2.0.0-rc.1',
      'v1.9.0',
    ]);
    expect(sections.first.lines, ['### Fixed', '- First fix.']);
    expect(() => sections.clear(), throwsUnsupportedError);
    expect(() => sections.first.lines.clear(), throwsUnsupportedError);
  });

  test('supports BOM, CRLF and Chinese unreleased headings', () {
    final sections = parseChangelog(
      '\uFEFF# Changelog\r\n## \u672a\u53d1\u5e03\r\n- Fix\r\n## v2.0.0 ##\r\n- Previous\r\n',
    );
    expect(sections.first.isUnreleased, isTrue);
    expect(sections.last.title, 'v2.0.0');
    expect(ChangelogSection('\u672a\u767c\u5e03', []).isUnreleased, isTrue);
  });

  test('does not split fenced code at apparent version headings', () {
    final sections = parseChangelog('''## v2.0.0
````text
## not a version
```
## still code
````
~~~
## also code
~~~
## v1.0.0
Old content
''');
    expect(sections.map((section) => section.title), ['v2.0.0', 'v1.0.0']);
    expect(sections.first.lines, contains('## still code'));
  });

  test('unversioned and empty documents have usable fallbacks', () {
    expect(parseChangelog('   \n'), isEmpty);
    expect(parseChangelog('## Unreleased\n\n'), isEmpty);
    final sections = parseChangelog('# Changelog\n- Standalone note');
    expect(sections.single.title, 'Changelog');
    expect(sections.single.lines.last, '- Standalone note');
  });

  test('large history stays separated without duplicating old content', () {
    final document = List.generate(
      1000,
      (i) => '## v1.$i.0\n- Entry $i\n',
    ).join();
    final sections = parseChangelog(document);
    expect(sections, hasLength(1000));
    expect(sections.first.lines, ['- Entry 0']);
    expect(sections.last.lines, ['- Entry 999']);
  });
}
