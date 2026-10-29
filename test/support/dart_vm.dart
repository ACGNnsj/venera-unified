import 'dart:io';
import 'package:path/path.dart' as p;

String dartExecutable() => _findDart(preferVm: true);

/// Full `dart` CLI executable (never `dartvm`): used only to warm up
/// build-hook native assets. It must not spawn probes: the CLI frontend runs
/// scripts in a wrapper child process, breaking pid matching/kill semantics.
String dartCliExecutable() => _findDart(preferVm: false);

/// Spawns a fixture probe script as a raw child process (preferring dartvm,
/// which runs the script in-process so pid matching and kill semantics hold).
/// [args] is the usual `--packages=...`, script path, and probe arguments.
///
/// Since sqlite3 3.x loads SQLite through build-hook native assets, raw
/// children can only resolve `sqlite3_initialize` when the hooks output
/// (`.dart_tool/native_assets.yaml` + `.dart_tool/lib/sqlite3.dll`) exists.
/// The flutter tool does not generate it, so the first spawn warms it up via
/// a one-off `dart run` of [hookWarmupScript] (a no-op script); later spawns
/// skip the warmup once the mapping mentions sqlite3.
Future<Process> startProbeProcess(List<String> args) async {
  await _ensureNativeAssets();
  return Process.start(dartExecutable(), args);
}

/// No-op script whose only purpose is triggering the hooks link phase.
const hookWarmupScript = 'test/support/hook_warmup.dart';

bool _hooksWarmed = false;

Future<void> _ensureNativeAssets() async {
  if (_hooksWarmed) return;
  _hooksWarmed = true;
  final mapping = File('.dart_tool/native_assets.yaml');
  if (mapping.existsSync() && mapping.readAsStringSync().contains('sqlite3')) {
    return;
  }
  final result = await Process.run(dartCliExecutable(), [
    'run',
    hookWarmupScript,
  ]);
  if (result.exitCode != 0) {
    stderr.writeln(
      'hook warmup failed (exit ${result.exitCode}): ${result.stderr}',
    );
  }
}

String _findDart({required bool preferVm}) {
  final executable = Platform.isWindows ? 'dart.exe' : 'dart';
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    for (final relative in [
      'bin/cache/dart-sdk/bin/$executable',
      'bin/$executable',
    ]) {
      final candidate = File(p.join(directory.path, relative));
      if (candidate.existsSync()) {
        final vm = File(
          p.join(
            candidate.parent.path,
            Platform.isWindows ? 'dartvm.exe' : 'dartvm',
          ),
        );
        if (!preferVm) return candidate.path;
        return vm.existsSync() ? vm.path : candidate.path;
      }
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError('Cannot locate the Dart SDK executable without a shell');
}
