import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/favorites/folder_name_validation.dart';

String _name(int length) => List.filled(length, 'x').join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Folder names are SQLite table names, and SQLite compares those
  // case-insensitively: "Books" and "books" can never coexist. The dialog has
  // to reject the case variant before it reaches CREATE TABLE, which used to
  // surface as a raw SqliteException.
  test('a new folder cannot reuse a name by letter case', () {
    expect(validateFolderName('books', folders: const ['Books']), isNotNull);
    expect(validateFolderName('BOOKS', folders: const ['Books']), isNotNull);
    expect(validateFolderName('books', folders: const []), isNull);
  });

  test('a rename may change only the letter case of its own name', () {
    expect(
      validateFolderName('books', folders: const ['Books'], renaming: 'Books'),
      isNull,
    );
    expect(
      validateFolderName('BOOKS', folders: const ['Books'], renaming: 'Books'),
      isNull,
    );
    expect(
      validateFolderName(
        'Books',
        folders: const ['Books', 'other'],
        renaming: 'other',
      ),
      isNotNull,
    );
  });

  test('a rename still cannot take another folder by letter case', () {
    expect(
      validateFolderName(
        'books',
        folders: const ['Books', 'other'],
        renaming: 'other',
      ),
      isNotNull,
    );
    expect(
      validateFolderName(
        'other',
        folders: const ['Books', 'other'],
        renaming: 'other',
      ),
      isNull,
    );
  });

  test('empty and oversized names keep their own errors', () {
    expect(validateFolderName('', folders: const []), isNotNull);
    expect(validateFolderName(_name(51), folders: const []), isNotNull);
    expect(validateFolderName(_name(50), folders: const []), isNull);
  });
}
