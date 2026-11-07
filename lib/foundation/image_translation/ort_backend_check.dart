import 'dart:typed_data';

import 'ort_ffi.dart';

/// 加速 EP 输出与 CPU 参考的逐元素平均绝对误差（MAE）阈值。
///
/// 与 Android 超分侧的 `NNAPI_COLOR_TOL`（0.04，值域 [0,1]）同一量级：
/// 加速 EP 在部分设备上可能只做 fp16 近似，正常数值误差通常远小于此；真正的
/// 通道错位/算子实现错误往往在 0.1 以上。检测模型输出是 [0,1] 概率图，
/// 直接用绝对 MAE 判定。
const double acceleratorMaeTolerance = 0.04;

/// logits 这类量级不固定的输出改用相对 MAE：`mae / mean(|cpu|)`。
///
/// fp16 噪声随数值量级放大，绝对阈值在 logits 上会误杀；相对误差则与
/// 量级无关。两种判据任一通过即视为一致。
const double acceleratorRelativeTolerance = 0.02;

/// 两个等长张量的逐元素平均绝对误差。
///
/// 长度不同返回 [double.infinity]，让调用方按“不可信”处理而不是崩溃。
double meanAbsoluteDifference(Float32List a, Float32List b) {
  if (a.length != b.length) return double.infinity;
  if (a.isEmpty) return 0;
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

/// 张量元素的平均绝对值，用于把 MAE 归一化成相对误差。
double meanMagnitude(Float32List values) {
  if (values.isEmpty) return 0;
  var sum = 0.0;
  for (var value in values) {
    sum += value.abs();
  }
  return sum / values.length;
}

/// 两个形状是否逐维相同。
bool sameTensorShape(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 加速 EP 首轮输出与 CPU 参考的比对结果。
class OrtAccelerationCheck {
  const OrtAccelerationCheck({
    required this.provider,
    required this.accepted,
    required this.mae,
    required this.relativeMae,
    this.outputName,
    this.detail,
  });

  /// 被验证的加速 EP（如 `XNNPACK`）。
  final String provider;

  /// 输出是否在容差内；false 表示这一页要回退 CPU。
  final bool accepted;

  /// 逐元素平均绝对误差；形状不一致时为 [double.infinity]。
  final double mae;

  /// `mae / mean(|cpu|)`；CPU 参考全零时为 0 或 1。
  final double relativeMae;

  /// 参与比对的输出名（模型通常只有一个输出）。
  final String? outputName;

  /// 形状不一致等附加说明。
  final String? detail;

  /// 供日志使用的一句话结论。
  String describe() {
    var output = outputName == null ? '' : ' [$outputName]';
    if (accepted) {
      return '$provider$output 与 CPU 参考一致'
          '（MAE ${_format(mae)}，相对 ${_format(relativeMae)}）';
    }
    return '$provider$output 与 CPU 参考偏差过大'
        '（MAE ${_format(mae)}，相对 ${_format(relativeMae)}；'
        '阈值 $acceleratorMaeTolerance / $acceleratorRelativeTolerance）'
        '，整页回退 CPU${detail == null ? '' : '（$detail）'}';
  }

  static String _format(double value) {
    if (!value.isFinite) return '∞';
    return value.toStringAsFixed(5);
  }
}

/// 比对一次加速推理与 CPU 参考推理，返回应当采用的那份输出。
class OrtCheckedRun {
  const OrtCheckedRun(this.outputs, this.check);

  /// 通过时是加速输出，未通过时是 CPU 输出；调用方可直接继续用。
  final Map<String, OrtOutput> outputs;

  final OrtAccelerationCheck check;
}

/// 用同一组输入分别跑加速会话与 CPU 会话，按首个输出判定是否可信。
///
/// 模型都是单输出，所以只比第一个；形状不一致直接判不可信。调用方在
/// [OrtCheckedRun.check] 未通过时应把本页剩余推理全部切到 CPU。
OrtCheckedRun runAgainstCpuReference({
  required OrtFfiSession accelerated,
  required OrtFfiSession cpu,
  required Map<String, OrtInput> inputs,
  double absoluteTolerance = acceleratorMaeTolerance,
  double relativeTolerance = acceleratorRelativeTolerance,
}) {
  var acceleratedOutputs = accelerated.run(inputs);
  var cpuOutputs = cpu.run(inputs);
  if (acceleratedOutputs.isEmpty || cpuOutputs.isEmpty) {
    return OrtCheckedRun(
      cpuOutputs,
      OrtAccelerationCheck(
        provider: accelerated.executionProvider ?? 'CPU',
        accepted: false,
        mae: double.infinity,
        relativeMae: double.infinity,
        detail: 'empty outputs',
      ),
    );
  }
  var name = acceleratedOutputs.keys.first;
  var acceleratedOutput = acceleratedOutputs[name];
  var cpuOutput = cpuOutputs[name];
  if (acceleratedOutput == null || cpuOutput == null) {
    return OrtCheckedRun(
      cpuOutputs,
      OrtAccelerationCheck(
        provider: accelerated.executionProvider ?? 'CPU',
        accepted: false,
        mae: double.infinity,
        relativeMae: double.infinity,
        outputName: name,
        detail: 'missing output "$name"',
      ),
    );
  }
  var check = evaluateAcceleratedOutput(
    provider: accelerated.executionProvider ?? 'CPU',
    cpu: cpuOutput,
    accelerated: acceleratedOutput,
    outputName: name,
    absoluteTolerance: absoluteTolerance,
    relativeTolerance: relativeTolerance,
  );
  return OrtCheckedRun(check.accepted ? acceleratedOutputs : cpuOutputs, check);
}

/// 纯判定：CPU 参考输出与加速输出的误差是否在容差内。
OrtAccelerationCheck evaluateAcceleratedOutput({
  required String provider,
  required OrtOutput cpu,
  required OrtOutput accelerated,
  String? outputName,
  double absoluteTolerance = acceleratorMaeTolerance,
  double relativeTolerance = acceleratorRelativeTolerance,
}) {
  if (!sameTensorShape(cpu.shape, accelerated.shape)) {
    return OrtAccelerationCheck(
      provider: provider,
      accepted: false,
      mae: double.infinity,
      relativeMae: double.infinity,
      outputName: outputName,
      detail: 'shape ${accelerated.shape} != CPU ${cpu.shape}',
    );
  }
  var mae = meanAbsoluteDifference(cpu.data, accelerated.data);
  var reference = meanMagnitude(cpu.data);
  var relative = reference < 1e-6
      ? (mae <= absoluteTolerance ? 0.0 : 1.0)
      : mae / reference;
  var accepted =
      mae <= absoluteTolerance ||
      (reference >= 1e-6 && relative <= relativeTolerance);
  return OrtAccelerationCheck(
    provider: provider,
    accepted: accepted,
    mae: mae,
    relativeMae: relative,
    outputName: outputName,
  );
}
