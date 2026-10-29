import 'package:venera_unified/foundation/translations.dart';

String? validateFolderName(
  String newFolderName, {
  required Iterable<String> folders,
  String? renaming,
}) {
  if (newFolderName.isEmpty) {
    return "Folder name cannot be empty".tl;
  } else if (newFolderName.length > 50) {
    return "Folder name is too long".tl;
  } else if (folders.any(
    // SQLite compares table names case-insensitively, so "Books" and "books"
    // cannot coexist. `renaming` is the folder being renamed: it must not
    // collide with itself, otherwise a case-only rename is rejected here.
    (folder) =>
        folder != renaming &&
        folder.toLowerCase() == newFolderName.toLowerCase(),
  )) {
    return "Folder already exists".tl;
  }
  return null;
}
