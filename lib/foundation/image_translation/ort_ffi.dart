import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'ort_runtime_choice.dart';

/// Minimal, synchronous binding to the ONNX Runtime C API.
///
/// The runtime library itself is bundled by the flutter_onnxruntime plugin
/// (onnxruntime.dll next to the exe on Windows, libonnxruntime.so in the APK,
/// ...). We bypass the plugin's platform channels entirely: its handlers run
/// inference on the platform thread and copy multi-MB tensors through the
/// message codec, which froze the UI. This binding is only ever used inside
/// the translation worker isolate, where blocking is fine.
///
/// The OrtApi struct is a stable, append-only table of function pointers; the
/// indices below were extracted from onnxruntime_c_api.h and are valid for
/// every 1.x release.
class OrtRuntime {
  OrtRuntime._(this._api, this.defaultExecutionProviders, this.runtimeSource);

  static OrtRuntime? _instance;

  final Pointer<Pointer<Void>> _api;

  /// 会话默认按这个顺序尝试挂 EP（见 [executionProvidersForPlatform]）：
  /// Windows ML 运行时是 ['DML']，Android 是 ['XNNPACK']，
  /// 其它平台（含随包分发的纯 CPU 运行库）为空，表示直接用默认 CPU EP。
  final List<String> defaultExecutionProviders;

  /// 实际载入的运行库说明，启动日志用。
  final String runtimeSource;

  static const _ortApiVersion = 16;

  /// 同一 EP 的挂载失败只打一次日志，避免 OCR 每页重复刷屏。
  static final _loggedProviderFailures = <String>{};

  // ONNXTensorElementDataType
  static const typeFloat32 = 1;
  static const typeInt64 = 7;

  static OrtRuntime open() {
    if (_instance != null) {
      return _instance!;
    }
    var choice = resolveOrtRuntime();
    var opened = _openLibrary(choice);
    var lib = opened.library;
    // const OrtApiBase* OrtGetApiBase(); OrtApiBase = { GetApi, GetVersionString }
    var getApiBase = lib
        .lookupFunction<
          Pointer<Pointer<Void>> Function(),
          Pointer<Pointer<Void>> Function()
        >('OrtGetApiBase');
    var apiBase = getApiBase();
    var getApi = apiBase[0]
        .cast<NativeFunction<Pointer<Pointer<Void>> Function(Uint32)>>()
        .asFunction<Pointer<Pointer<Void>> Function(int)>();
    var api = getApi(_ortApiVersion);
    if (api == nullptr) {
      throw Exception('ONNX Runtime API version $_ortApiVersion unavailable');
    }
    return _instance = OrtRuntime._(
      api,
      opened.executionProviders,
      opened.source,
    );
  }

  static ({
    DynamicLibrary library,
    List<String> executionProviders,
    String source,
  })
  _openLibrary(OrtRuntimeChoice choice) {
    if (choice.isWindowsMl) {
      try {
        return (
          library: DynamicLibrary.open(choice.windowsMlDllPath!),
          executionProviders: choice.executionProviders,
          source: 'windows-ml ${choice.windowsMlDllPath}',
        );
      } catch (_) {
        // 框架包里的 DLL 载入失败（权限、版本、依赖缺失）就当没有它，
        // 继续往下试随包分发的那份。
      }
    }
    var candidates = <String Function()>[];
    if (Platform.isWindows) {
      candidates.add(() => 'onnxruntime.dll');
    } else if (Platform.isAndroid) {
      candidates.add(() => 'libonnxruntime.so');
    } else if (Platform.isLinux) {
      // Try the soname first: it matches the copy the plugin already loaded,
      // avoiding a second copy of the runtime in this process (VeneraX@51bbdd4d).
      candidates.add(() => 'libonnxruntime.so.1');
      candidates.add(() => 'libonnxruntime.so');
    } else {
      candidates.add(() => 'libonnxruntime.dylib');
    }
    // 选了 Windows ML 却没能载入它的运行时：此时手里这份是纯 CPU 的，
    // 别再拿 DML 去试。其余情况沿用平台候选（Android 的 XNNPACK）。
    var fallbackProviders = choice.isWindowsMl
        ? const <String>[]
        : choice.executionProviders;
    Object? lastError;
    // On iOS/macOS the runtime may be statically linked into the process.
    try {
      var process = DynamicLibrary.process();
      if (process.providesSymbol('OrtGetApiBase')) {
        return (
          library: process,
          executionProviders: fallbackProviders,
          source: 'process',
        );
      }
    } catch (_) {}
    for (var candidate in candidates) {
      try {
        return (
          library: DynamicLibrary.open(candidate()),
          executionProviders: fallbackProviders,
          source: candidate(),
        );
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Failed to load ONNX Runtime library: $lastError');
  }

  // --- OrtApi table indices (see class comment) ---
  static const _iGetErrorMessage = 2;
  static const _iCreateEnv = 3;
  static const _iCreateSession = 7;
  static const _iRun = 9;
  static const _iCreateSessionOptions = 10;
  static const _iSetIntraOpNumThreads = 24;
  // 通用的 SessionOptionsAppendExecutionProvider（1.12 起）：DML 没有专用的 C 入口，
  // 要按 provider_name='DML' 走这条；CUDA 另有专用槽位。
  static const _iAppendExecutionProvider = 216;
  static const _iSessionGetInputCount = 30;
  static const _iSessionGetOutputCount = 31;
  static const _iSessionGetInputName = 36;
  static const _iSessionGetOutputName = 37;
  static const _iCreateTensorWithDataAsOrtValue = 49;
  static const _iGetTensorMutableData = 51;
  static const _iGetDimensionsCount = 61;
  static const _iGetDimensions = 62;
  static const _iGetTensorShapeElementCount = 64;
  static const _iGetTensorTypeAndShape = 65;
  static const _iCreateCpuMemoryInfo = 69;
  static const _iAllocatorFree = 76;
  static const _iGetAllocatorWithDefaultOptions = 78;
  static const _iReleaseStatus = 93;
  static const _iReleaseSession = 95;
  static const _iReleaseValue = 96;
  static const _iReleaseTensorTypeAndShapeInfo = 99;
  static const _iReleaseSessionOptions = 100;

  // Cached typed function lookups.
  late final _getErrorMessage = _api[_iGetErrorMessage]
      .cast<NativeFunction<Pointer<Utf8> Function(Pointer<Void>)>>()
      .asFunction<Pointer<Utf8> Function(Pointer<Void>)>();
  late final _releaseStatus = _releaser(_iReleaseStatus);

  void Function(Pointer<Void>) _releaser(int index) {
    return _api[index]
        .cast<NativeFunction<Void Function(Pointer<Void>)>>()
        .asFunction<void Function(Pointer<Void>)>();
  }

  /// Throws if [status] is an error; releases it either way.
  void _check(Pointer<Void> status) {
    if (status == nullptr) return;
    var message = _getErrorMessage(status).toDartString();
    _releaseStatus(status);
    throw Exception('ONNX Runtime error: $message');
  }

  /// 挂一个执行提供者；失败抛异常（异常里带 ORT 的错误文本）。
  ///
  /// 统一走通用入口 [SessionOptionsAppendExecutionProvider]，按名字交给运行库
  /// 自己的注册表查。NNAPI 曾经只能靠专用导出符号，但它从 Android 15 起被
  /// 弃用、Android 17 的部分设备已经不再带 `libneuralnetworks.so`，候选里
  /// 已移除（实测见 doc/experiments/image_translation.zh.md）。
  void _applyExecutionProvider(Pointer<Void> options, String provider) {
    _appendGenericExecutionProvider(options, provider);
  }

  void _appendGenericExecutionProvider(Pointer<Void> options, String provider) {
    // OrtStatus* SessionOptionsAppendExecutionProvider(
    //     OrtSessionOptions*, const char* provider_name,
    //     const char* const* keys, const char* const* values, size_t num_keys)
    var append = _api[_iAppendExecutionProvider]
        .cast<
          NativeFunction<
            Pointer<Void> Function(
              Pointer<Void>,
              Pointer<Utf8>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Size,
            )
          >
        >()
        .asFunction<
          Pointer<Void> Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Pointer<Utf8>>,
            Pointer<Pointer<Utf8>>,
            int,
          )
        >();
    var name = provider.toNativeUtf8();
    try {
      _check(append(options, name, nullptr, nullptr, 0));
    } finally {
      calloc.free(name);
    }
  }

  /// 逐项探测候选 EP 能否在当前运行库/设备上挂载。
  ///
  /// 只建 session options 并 append，不建会话，不跑推理，开销很小。
  List<OrtExecutionProviderProbe> probeExecutionProviders() {
    return [for (var provider in defaultExecutionProviders) _probe(provider)];
  }

  OrtExecutionProviderProbe _probe(String provider) {
    var optionsOut = calloc<Pointer<Void>>();
    Pointer<Void>? options;
    try {
      var createOptions = _api[_iCreateSessionOptions]
          .cast<
            NativeFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>
          >()
          .asFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>();
      _check(createOptions(optionsOut));
      options = optionsOut.value;
      _applyExecutionProvider(options, provider);
      return OrtExecutionProviderProbe(name: provider, available: true);
    } on Exception catch (e) {
      return OrtExecutionProviderProbe(
        name: provider,
        available: false,
        detail: _shortError(e),
      );
    } finally {
      if (options != null) _releaser(_iReleaseSessionOptions)(options);
      calloc.free(optionsOut);
    }
  }

  /// 启动时打印一次诊断：平台/ABI、用哪份运行库、候选 EP 与可挂载性。
  ///
  /// 日志前缀统一为 `[ORT]`，真机排障时 `adb logcat | grep '\[ORT\]'` 即可。
  static Future<void> logStartupDiagnostics() async {
    try {
      var choice = resolveOrtRuntime();
      debugPrint(
        '[ORT] platform=${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion} abi=${Abi.current()}',
      );
      debugPrint(
        '[ORT] runtime=${choice.isWindowsMl ? 'Windows ML ${choice.windowsMlDllPath}' : 'bundled'} '
        'candidates=${choice.executionProviders.isEmpty ? '[CPU]' : choice.executionProviders}',
      );
      var rt = open();
      debugPrint('[ORT] loaded=${rt.runtimeSource} api=$_ortApiVersion');
      var probes = rt.probeExecutionProviders();
      if (probes.isEmpty) {
        debugPrint('[ORT] CPU: 可用（无加速候选）');
        return;
      }
      for (var probe in probes) {
        debugPrint('[ORT] ${probe.describe()}');
      }
      debugPrint('[ORT] CPU: 可用（默认回退）');
    } catch (e) {
      debugPrint('[ORT] 启动诊断失败：${_shortError(e)}');
    }
  }

  Pointer<Void>? _env;
  Pointer<Void>? _memoryInfo;
  Pointer<Void>? _allocator;

  Pointer<Void> get env {
    if (_env == null) {
      var createEnv = _api[_iCreateEnv]
          .cast<
            NativeFunction<
              Pointer<Void> Function(
                Int32,
                Pointer<Utf8>,
                Pointer<Pointer<Void>>,
              )
            >
          >()
          .asFunction<
            Pointer<Void> Function(int, Pointer<Utf8>, Pointer<Pointer<Void>>)
          >();
      var out = calloc<Pointer<Void>>();
      var name = 'venera'.toNativeUtf8();
      try {
        _check(createEnv(3 /* ORT_LOGGING_LEVEL_ERROR */, name, out));
        _env = out.value;
      } finally {
        calloc.free(out);
        calloc.free(name);
      }
    }
    return _env!;
  }

  Pointer<Void> get memoryInfo {
    if (_memoryInfo == null) {
      var create = _api[_iCreateCpuMemoryInfo]
          .cast<
            NativeFunction<
              Pointer<Void> Function(Int32, Int32, Pointer<Pointer<Void>>)
            >
          >()
          .asFunction<
            Pointer<Void> Function(int, int, Pointer<Pointer<Void>>)
          >();
      var out = calloc<Pointer<Void>>();
      try {
        _check(create(0 /* OrtDeviceAllocator */, 0 /* default */, out));
        _memoryInfo = out.value;
      } finally {
        calloc.free(out);
      }
    }
    return _memoryInfo!;
  }

  Pointer<Void> get allocator {
    if (_allocator == null) {
      var get = _api[_iGetAllocatorWithDefaultOptions]
          .cast<
            NativeFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>
          >()
          .asFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>();
      var out = calloc<Pointer<Void>>();
      try {
        _check(get(out));
        _allocator = out.value;
      } finally {
        calloc.free(out);
      }
    }
    return _allocator!;
  }

  void allocatorFree(Pointer<Void> p) {
    var free = _api[_iAllocatorFree]
        .cast<
          NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>
        >()
        .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>();
    _check(free(allocator, p));
  }
}

/// 一个 EP 在当前运行库/设备上能否挂载。
class OrtExecutionProviderProbe {
  const OrtExecutionProviderProbe({
    required this.name,
    required this.available,
    this.detail,
  });

  final String name;
  final bool available;
  final String? detail;

  String describe() {
    if (available) return '$name: 可用';
    return '$name: 不可用${detail == null ? '' : '（$detail）'}';
  }
}

String _shortError(Object error) {
  var text = error.toString().replaceFirst('Exception: ', '');
  if (text.length <= 200) return text;
  return '${text.substring(0, 200)}…';
}

/// A float32 or int64 input tensor description.
class OrtInput {
  OrtInput.float32(Float32List this.f32Data, this.shape) : i64Data = null;
  OrtInput.int64(Int64List this.i64Data, this.shape) : f32Data = null;

  final Float32List? f32Data;
  final Int64List? i64Data;
  final List<int> shape;
}

/// One inference output: float data plus its shape. [data] is a copy owned by
/// Dart, safe to use after the run.
class OrtOutput {
  OrtOutput(this.data, this.shape);

  final Float32List data;
  final List<int> shape;
}

/// Synchronous inference session. Only use inside a worker isolate.
class OrtFfiSession {
  OrtFfiSession._(
    this._rt,
    this._session,
    this.inputNames,
    this.outputNames,
    this.executionProvider,
  );

  final OrtRuntime _rt;
  final Pointer<Void> _session;
  final List<String> inputNames;
  final List<String> outputNames;

  /// 实际生效的执行提供者；null 表示默认的 CPU EP。
  ///
  /// 'DML' 需要带 DirectML 的运行库，'XNNPACK' 需要 Android 版；
  /// 运行库里没编进对应 EP 时就挂不上，[open] 会继续试下一个。
  final String? executionProvider;

  /// 建会话。[executionProvider] 明确指定时只要它，失败直接抛错（便于诊断）；
  /// 传 null 时按运行库的候选顺序逐个尝试，最后落到 CPU：GPU/NPU 会话建不起来
  /// （驱动、显存、算子不支持）时功能本身照旧可用，而不是把整页翻译报错。
  static OrtFfiSession open(
    String modelPath, {
    int? intraOpThreads,
    String? executionProvider,
  }) {
    var rt = OrtRuntime.open();
    if (executionProvider != null) {
      return _open(rt, modelPath, intraOpThreads, executionProvider);
    }
    for (var candidate in rt.defaultExecutionProviders) {
      try {
        return _open(rt, modelPath, intraOpThreads, candidate);
      } on Exception catch (e) {
        // 这台设备上建不起来，换下一个候选。同一 EP 只记一次，避免 OCR
        // 每页重复刷日志。
        if (OrtRuntime._loggedProviderFailures.add(candidate)) {
          debugPrint('[ORT] $candidate 建会话失败，尝试下一个：${_shortError(e)}');
        }
      }
    }
    debugPrint('[ORT] 加速 EP 均不可用，本页使用 CPU');
    return _open(rt, modelPath, intraOpThreads, null);
  }

  /// 建一个纯 CPU 会话，不尝试任何 EP。
  ///
  /// 用于加速 EP 输出比对：同一模型同时持有加速与 CPU 两份会话，首轮双跑后
  /// 只保留通过比对的那份输出。
  static OrtFfiSession openCpu(String modelPath, {int? intraOpThreads}) {
    return _open(OrtRuntime.open(), modelPath, intraOpThreads, null);
  }

  static OrtFfiSession _open(
    OrtRuntime rt,
    String modelPath,
    int? intraOpThreads,
    String? executionProvider,
  ) {
    var optionsOut = calloc<Pointer<Void>>();
    var sessionOut = calloc<Pointer<Void>>();
    Pointer<Void>? options;
    try {
      var createOptions = rt._api[OrtRuntime._iCreateSessionOptions]
          .cast<
            NativeFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>
          >()
          .asFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>();
      rt._check(createOptions(optionsOut));
      options = optionsOut.value;
      if (intraOpThreads != null) {
        var setThreads = rt._api[OrtRuntime._iSetIntraOpNumThreads]
            .cast<
              NativeFunction<Pointer<Void> Function(Pointer<Void>, Int32)>
            >()
            .asFunction<Pointer<Void> Function(Pointer<Void>, int)>();
        rt._check(setThreads(options, intraOpThreads));
      }
      if (executionProvider != null) {
        rt._applyExecutionProvider(options, executionProvider);
      }

      // ORTCHAR_T is wchar_t (UTF-16) on Windows and char (UTF-8) elsewhere.
      Pointer<Void> pathPtr;
      if (Platform.isWindows) {
        var units = modelPath.codeUnits;
        var p = calloc<Uint16>(units.length + 1);
        p.asTypedList(units.length + 1)
          ..setRange(0, units.length, units)
          ..[units.length] = 0;
        pathPtr = p.cast();
      } else {
        pathPtr = modelPath.toNativeUtf8().cast();
      }
      try {
        var createSession = rt._api[OrtRuntime._iCreateSession]
            .cast<
              NativeFunction<
                Pointer<Void> Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Pointer<Void>>,
                )
              >
            >()
            .asFunction<
              Pointer<Void> Function(
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Pointer<Void>>,
              )
            >();
        rt._check(createSession(rt.env, pathPtr, options, sessionOut));
      } finally {
        calloc.free(pathPtr);
      }
      var session = sessionOut.value;
      var inputNames = _names(
        rt,
        session,
        OrtRuntime._iSessionGetInputCount,
        OrtRuntime._iSessionGetInputName,
      );
      var outputNames = _names(
        rt,
        session,
        OrtRuntime._iSessionGetOutputCount,
        OrtRuntime._iSessionGetOutputName,
      );
      return OrtFfiSession._(
        rt,
        session,
        inputNames,
        outputNames,
        executionProvider,
      );
    } finally {
      if (options != null) {
        rt._releaser(OrtRuntime._iReleaseSessionOptions)(options);
      }
      calloc.free(optionsOut);
      calloc.free(sessionOut);
    }
  }

  static List<String> _names(
    OrtRuntime rt,
    Pointer<Void> session,
    int countIndex,
    int nameIndex,
  ) {
    var getCount = rt._api[countIndex]
        .cast<
          NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>
        >()
        .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>();
    var getName = rt._api[nameIndex]
        .cast<
          NativeFunction<
            Pointer<Void> Function(
              Pointer<Void>,
              Size,
              Pointer<Void>,
              Pointer<Pointer<Utf8>>,
            )
          >
        >()
        .asFunction<
          Pointer<Void> Function(
            Pointer<Void>,
            int,
            Pointer<Void>,
            Pointer<Pointer<Utf8>>,
          )
        >();
    var countOut = calloc<Size>();
    var nameOut = calloc<Pointer<Utf8>>();
    try {
      rt._check(getCount(session, countOut));
      var names = <String>[];
      for (var i = 0; i < countOut.value; i++) {
        rt._check(getName(session, i, rt.allocator, nameOut));
        names.add(nameOut.value.toDartString());
        rt.allocatorFree(nameOut.value.cast());
      }
      return names;
    } finally {
      calloc.free(countOut);
      calloc.free(nameOut);
    }
  }

  /// Runs the session. Returns outputs in [requestedOutputs] order (all
  /// outputs when null). Blocking; worker isolate only.
  Map<String, OrtOutput> run(
    Map<String, OrtInput> inputs, {
    List<String>? requestedOutputs,
  }) {
    var outputs = requestedOutputs ?? outputNames;
    return _execute(inputs, outputs, (values) {
      var result = <String, OrtOutput>{};
      for (var i = 0; i < outputs.length; i++) {
        result[outputs[i]] = _readOutput(values[i]);
      }
      return result;
    });
  }

  /// Runs the session and returns the argmax over the LAST row of a
  /// [rows, vocab]-shaped output, reading native memory directly. This is the
  /// hot path of greedy decoding: the full logits tensor (dozens of MB per
  /// step) is never copied into Dart.
  int runArgmaxLastRow(Map<String, OrtInput> inputs, String outputName) {
    return _execute(inputs, [outputName], (values) {
      var value = values[0];
      var (shape, elementCount) = _readShape(value);
      var vocab = shape.last;
      var dataOut = calloc<Pointer<Void>>();
      try {
        var getData = _rt._api[OrtRuntime._iGetTensorMutableData]
            .cast<
              NativeFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
              >
            >()
            .asFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
            >();
        _rt._check(getData(value, dataOut));
        var lastRow = (dataOut.value.cast<Float>() + (elementCount - vocab))
            .asTypedList(vocab);
        var best = 0;
        var bestScore = lastRow[0];
        for (var i = 1; i < vocab; i++) {
          if (lastRow[i] > bestScore) {
            bestScore = lastRow[i];
            best = i;
          }
        }
        return best;
      } finally {
        calloc.free(dataOut);
      }
    });
  }

  T _execute<T>(
    Map<String, OrtInput> inputs,
    List<String> outputs,
    T Function(List<Pointer<Void>> outputValues) read,
  ) {
    var rt = _rt;
    var inputCount = inputs.length;
    var nativeBuffers = <Pointer<Void>>[];
    var inputValues = calloc<Pointer<Void>>(inputCount);
    var inputNamePtrs = calloc<Pointer<Utf8>>(inputCount);
    var outputNamePtrs = calloc<Pointer<Utf8>>(outputs.length);
    var outputValues = calloc<Pointer<Void>>(outputs.length);
    var utf8Names = <Pointer<Utf8>>[];
    try {
      var createTensor = rt._api[OrtRuntime._iCreateTensorWithDataAsOrtValue]
          .cast<
            NativeFunction<
              Pointer<Void> Function(
                Pointer<Void>, // memory info
                Pointer<Void>, // data
                Size, // data length in bytes
                Pointer<Int64>, // shape
                Size, // shape length
                Int32, // element type
                Pointer<Pointer<Void>>,
              )
            >
          >()
          .asFunction<
            Pointer<Void> Function(
              Pointer<Void>,
              Pointer<Void>,
              int,
              Pointer<Int64>,
              int,
              int,
              Pointer<Pointer<Void>>,
            )
          >();
      var index = 0;
      var valueOut = calloc<Pointer<Void>>();
      try {
        for (var entry in inputs.entries) {
          var input = entry.value;
          Pointer<Void> dataPtr;
          int byteLength;
          int elementType;
          if (input.f32Data != null) {
            var data = input.f32Data!;
            var p = calloc<Float>(data.length);
            p.asTypedList(data.length).setAll(0, data);
            dataPtr = p.cast();
            byteLength = data.length * 4;
            elementType = OrtRuntime.typeFloat32;
          } else {
            var data = input.i64Data!;
            var p = calloc<Int64>(data.length);
            p.asTypedList(data.length).setAll(0, data);
            dataPtr = p.cast();
            byteLength = data.length * 8;
            elementType = OrtRuntime.typeInt64;
          }
          nativeBuffers.add(dataPtr);
          var shapePtr = calloc<Int64>(input.shape.length);
          shapePtr.asTypedList(input.shape.length).setAll(0, input.shape);
          nativeBuffers.add(shapePtr.cast());
          rt._check(
            createTensor(
              rt.memoryInfo,
              dataPtr,
              byteLength,
              shapePtr,
              input.shape.length,
              elementType,
              valueOut,
            ),
          );
          inputValues[index] = valueOut.value;
          var namePtr = entry.key.toNativeUtf8();
          utf8Names.add(namePtr);
          inputNamePtrs[index] = namePtr;
          index++;
        }
      } finally {
        calloc.free(valueOut);
      }
      for (var i = 0; i < outputs.length; i++) {
        var namePtr = outputs[i].toNativeUtf8();
        utf8Names.add(namePtr);
        outputNamePtrs[i] = namePtr;
        outputValues[i] = nullptr;
      }

      var runFn = rt._api[OrtRuntime._iRun]
          .cast<
            NativeFunction<
              Pointer<Void> Function(
                Pointer<Void>, // session
                Pointer<Void>, // run options
                Pointer<Pointer<Utf8>>, // input names
                Pointer<Pointer<Void>>, // input values
                Size,
                Pointer<Pointer<Utf8>>, // output names
                Size,
                Pointer<Pointer<Void>>, // output values
              )
            >
          >()
          .asFunction<
            Pointer<Void> Function(
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Void>>,
              int,
              Pointer<Pointer<Utf8>>,
              int,
              Pointer<Pointer<Void>>,
            )
          >();
      rt._check(
        runFn(
          _session,
          nullptr,
          inputNamePtrs,
          inputValues,
          inputCount,
          outputNamePtrs,
          outputs.length,
          outputValues,
        ),
      );

      return read([for (var i = 0; i < outputs.length; i++) outputValues[i]]);
    } finally {
      var releaseValue = rt._releaser(OrtRuntime._iReleaseValue);
      for (var i = 0; i < inputCount; i++) {
        if (inputValues[i] != nullptr) releaseValue(inputValues[i]);
      }
      for (var i = 0; i < outputs.length; i++) {
        if (outputValues[i] != nullptr) releaseValue(outputValues[i]);
      }
      for (var p in nativeBuffers) {
        calloc.free(p);
      }
      for (var p in utf8Names) {
        calloc.free(p);
      }
      calloc.free(inputValues);
      calloc.free(inputNamePtrs);
      calloc.free(outputNamePtrs);
      calloc.free(outputValues);
    }
  }

  /// Reads a tensor's shape and total element count.
  (List<int>, int) _readShape(Pointer<Void> value) {
    var rt = _rt;
    var infoOut = calloc<Pointer<Void>>();
    Pointer<Void>? info;
    try {
      var getInfo = rt._api[OrtRuntime._iGetTensorTypeAndShape]
          .cast<
            NativeFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
            >
          >()
          .asFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
          >();
      rt._check(getInfo(value, infoOut));
      info = infoOut.value;

      var dimCountOut = calloc<Size>();
      var elementCountOut = calloc<Size>();
      try {
        var getDimCount = rt._api[OrtRuntime._iGetDimensionsCount]
            .cast<
              NativeFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Size>)
              >
            >()
            .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>();
        rt._check(getDimCount(info, dimCountOut));
        var dims = calloc<Int64>(dimCountOut.value);
        try {
          var getDims = rt._api[OrtRuntime._iGetDimensions]
              .cast<
                NativeFunction<
                  Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, Size)
                >
              >()
              .asFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, int)
              >();
          rt._check(getDims(info, dims, dimCountOut.value));
          var shape = List<int>.generate(dimCountOut.value, (i) => dims[i]);

          var getElementCount = rt._api[OrtRuntime._iGetTensorShapeElementCount]
              .cast<
                NativeFunction<
                  Pointer<Void> Function(Pointer<Void>, Pointer<Size>)
                >
              >()
              .asFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Size>)
              >();
          rt._check(getElementCount(info, elementCountOut));
          return (shape, elementCountOut.value);
        } finally {
          calloc.free(dims);
        }
      } finally {
        calloc.free(dimCountOut);
        calloc.free(elementCountOut);
      }
    } finally {
      if (info != null) {
        rt._releaser(OrtRuntime._iReleaseTensorTypeAndShapeInfo)(info);
      }
      calloc.free(infoOut);
    }
  }

  OrtOutput _readOutput(Pointer<Void> value) {
    var rt = _rt;
    var (shape, elementCount) = _readShape(value);
    var dataOut = calloc<Pointer<Void>>();
    try {
      var getData = rt._api[OrtRuntime._iGetTensorMutableData]
          .cast<
            NativeFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
            >
          >()
          .asFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
          >();
      rt._check(getData(value, dataOut));
      // Copy out: the OrtValue is released right after this call.
      var view = dataOut.value.cast<Float>().asTypedList(elementCount);
      return OrtOutput(Float32List.fromList(view), shape);
    } finally {
      calloc.free(dataOut);
    }
  }

  void close() {
    _rt._releaser(OrtRuntime._iReleaseSession)(_session);
  }
}
