import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:venera_unified/foundation/image_translation/ort_backend_check.dart';
import 'package:venera_unified/foundation/image_translation/ort_ffi.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatefulWidget {
  const _ProbeApp();

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  final _lines = <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _emit(String line) {
    debugPrint(line);
    _lines.add(line);
    if (mounted) setState(() {});
  }

  void _json(String step, Map<String, Object?> fields) {
    _emit('ORT_PROBE ${jsonEncode({'step': step, ...fields})}');
  }

  String _err(Object error) {
    var text = error.toString().replaceFirst('Exception: ', '');
    return text.length <= 200 ? text : '${text.substring(0, 200)}…';
  }

  double _min(Float32List data) => data.reduce((a, b) => a < b ? a : b);

  double _max(Float32List data) => data.reduce((a, b) => a > b ? a : b);

  double _mean(Float32List data) {
    if (data.isEmpty) return 0;
    var sum = 0.0;
    for (var v in data) {
      sum += v;
    }
    return sum / data.length;
  }

  Float32List _pattern(List<int> shape) {
    var elements = shape.fold<int>(1, (a, b) => a * b);
    var pattern = Float32List(elements);
    for (var i = 0; i < elements; i++) {
      pattern[i] = ((i * 37 + 11) % 251) / 250.0;
    }
    return pattern;
  }

  void _compare(
    String label,
    OrtFfiSession acceleratedSession,
    OrtFfiSession cpuSession,
    List<int> shape,
    Float32List pattern,
  ) {
    try {
      var inputs = <String, OrtInput>{
        for (var name in acceleratedSession.inputNames)
          name: OrtInput.float32(Float32List.fromList(pattern), shape),
      };
      // Warm up both sessions so the timed run doesn't pay for lazy kernel setup.
      acceleratedSession.run(inputs);
      cpuSession.run(inputs);
      var acceleratedWatch = Stopwatch()..start();
      var accelerated = acceleratedSession.run(inputs);
      acceleratedWatch.stop();
      var referenceWatch = Stopwatch()..start();
      var reference = cpuSession.run(inputs);
      referenceWatch.stop();
      var name = accelerated.keys.first;
      var check = evaluateAcceleratedOutput(
        provider: label,
        cpu: reference[name]!,
        accelerated: accelerated[name]!,
        outputName: name,
      );
      var cpuOut = reference[name]!;
      var accOut = accelerated[name]!;
      _json('run', {
        'peer': label,
        'shape': shape,
        'ok': true,
        'outputShape': accOut.shape,
        'accepted': check.accepted,
        'mae': check.mae,
        'relative': check.relativeMae,
        'accMs': acceleratedWatch.elapsedMilliseconds,
        'cpuMs': referenceWatch.elapsedMilliseconds,
        'cpuLen': cpuOut.data.length,
        'accLen': accOut.data.length,
        'cpuMin': cpuOut.data.isEmpty ? null : _min(cpuOut.data),
        'cpuMax': cpuOut.data.isEmpty ? null : _max(cpuOut.data),
        'cpuMean': _mean(cpuOut.data),
        'accMin': accOut.data.isEmpty ? null : _min(accOut.data),
        'accMax': accOut.data.isEmpty ? null : _max(accOut.data),
        'accMean': _mean(accOut.data),
        'cpuFirst': cpuOut.data.take(3).toList(),
        'accFirst': accOut.data.take(3).toList(),
        'inputSum': pattern.reduce((a, b) => a + b),
      });
    } catch (e) {
      _json('run', {
        'peer': label,
        'shape': shape,
        'ok': false,
        'error': _err(e),
      });
    }
  }

  Future<void> _run() async {
    _json('env', {
      'platform': Platform.operatingSystem,
      'version': Platform.operatingSystemVersion,
      'abi': Abi.current().toString(),
      'dart': Platform.version,
    });

    try {
      await OrtRuntime.logStartupDiagnostics();
      _json('startup-log', {'ok': true});
    } catch (e) {
      _json('startup-log', {'ok': false, 'error': _err(e)});
    }

    OrtRuntime rt;
    try {
      rt = OrtRuntime.open();
    } catch (e) {
      _json('runtime', {'ok': false, 'error': _err(e)});
      _json('done', {'lines': _lines.length});
      return;
    }
    try {
      var probes = rt.probeExecutionProviders();
      if (probes.isEmpty) {
        _json('probe', {'ep': 'CPU', 'available': true, 'detail': null});
      }
      for (var probe in probes) {
        _json('probe', {
          'ep': probe.name,
          'available': probe.available,
          'detail': probe.detail,
        });
      }
    } catch (e) {
      _json('probe', {'ep': 'runtime', 'available': false, 'error': _err(e)});
    }

    File model;
    try {
      var data = await rootBundle.load('assets/models/anime4k_acnet.onnx');
      var dir = await getTemporaryDirectory();
      model = File('${dir.path}/anime4k_acnet.onnx');
      await model.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      _json('model', {'bytes': await model.length(), 'path': model.path});
    } catch (e) {
      _json('model', {'ok': false, 'error': _err(e)});
      _json('done', {'lines': _lines.length});
      return;
    }

    OrtFfiSession? cpu;
    OrtFfiSession? xnnpack;
    try {
      cpu = OrtFfiSession.openCpu(model.path, intraOpThreads: 1);
      _json('session', {
        'ep': 'CPU',
        'ok': true,
        'inputs': cpu.inputNames,
        'outputs': cpu.outputNames,
      });
    } catch (e) {
      _json('session', {'ep': 'CPU', 'ok': false, 'error': _err(e)});
    }
    try {
      xnnpack = OrtFfiSession.open(
        model.path,
        intraOpThreads: 1,
        executionProvider: 'XNNPACK',
      );
      _json('session', {
        'ep': 'XNNPACK',
        'ok': true,
        'actual': xnnpack.executionProvider,
        'inputs': xnnpack.inputNames,
        'outputs': xnnpack.outputNames,
      });
    } catch (e) {
      _json('session', {'ep': 'XNNPACK', 'ok': false, 'error': _err(e)});
    }

    var shapes = <List<int>>[
      [1, 1, 256, 256],
      [1, 1, 128, 128],
      [1, 1, 64, 64],
    ];
    if (cpu != null) {
      for (var shape in shapes) {
        var pattern = _pattern(shape);
        if (xnnpack != null) _compare('XNNPACK', xnnpack, cpu, shape, pattern);
      }
    }

    cpu?.close();
    xnnpack?.close();
    _json('done', {'lines': _lines.length});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('ORT EP probe')),
        body: SafeArea(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: _lines.length,
            itemBuilder: (context, index) => Text(
              _lines[index],
              style: const TextStyle(fontSize: 9, fontFamily: 'monospace'),
            ),
          ),
        ),
      ),
    );
  }
}
