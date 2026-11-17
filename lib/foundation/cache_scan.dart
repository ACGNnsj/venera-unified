import 'dart:isolate';
import 'dart:io';
import 'sqlite_connection.dart';

class CacheScanResult {
  const CacheScanResult(this.totalSize, this.unmanagedFiles);
  final int totalSize;
  final List<String> unmanagedFiles;
}

typedef CacheScanner =
    Future<CacheScanResult> Function(String dbPath, String directory);

Future<CacheScanResult> scanCacheDirectory(String dbPath, String dir) async {
  return Isolate.run(() async {
    int totalSize = 0;
    List<String> unmanagedFiles = [];
    var db = openSqliteDatabase(dbPath);
    try {
      // One SELECT for the whole table replaces the per-file query (N+1
      // becomes 1); (dir, name) pairs are tiny strings held in a set.
      final managed = <String>{
        for (final row in db.select('SELECT dir, name FROM cache'))
          '${row['dir']}\x00${row['name']}',
      };
      await for (var file in Directory(dir).list(recursive: true)) {
        if (file is File) {
          var size = await file.length();
          var segments = file.uri.pathSegments;
          var name = segments.last;
          var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
          if (managed.contains('$dir\x00$name')) {
            totalSize += size;
          } else {
            unmanagedFiles.add(file.path);
          }
        }
      }
    } finally {
      db.close();
    }
    return CacheScanResult(totalSize, unmanagedFiles);
  });
}
