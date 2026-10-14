import 'dart:io';

Future<Link> createDirectoryAlias(String path, String target) async {
  if (Platform.isWindows) {
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '\$ErrorActionPreference = "Stop"; '
            'New-Item -ItemType Junction -Path \$env:SYNC_ALIAS '
            '-Target \$env:SYNC_TARGET | Out-Null',
      ],
      environment: {'SYNC_ALIAS': path, 'SYNC_TARGET': target},
    );
    if (result.exitCode != 0) {
      throw StateError('Cannot create directory alias: ${result.stderr}');
    }
  } else {
    await Link(path).create(target);
  }
  return Link(path);
}
