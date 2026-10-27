/// 书源脚本返回的字段类型经常写错（数字当字符串、单个字符串当列表、时间戳当
/// 字符串等）。下面这组转换只做归一化，不改正常数据的语义，目的是让 `fromJson`
/// 不再因为一个字段类型不对就抛 TypeError。
///
/// 但「类型写错」和「根本不是数据」是两件事：书源脚本把回调函数（JS function）
/// 塞进字段时，那是一条无效结果，必须继续抛错让上层按失败处理、并释放引用。
/// 所以这里的原则是——**只在字符串/数字/布尔之间互相归一，遇到其它对象一律抛**。
///
/// 这些函数刻意不依赖任何其它模块，方便 `models.dart` 直接 import。
Never _rejectUnsupported(dynamic value) {
  throw ArgumentError.value(value, 'value', '书源返回了无法转换的值');
}

String coerceString(dynamic value, {String fallback = ''}) {
  if (value == null) return fallback;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  _rejectUnsupported(value);
}

String? coerceNullableString(dynamic value) {
  if (value == null) return null;
  return coerceString(value);
}

int? coerceInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is bool) return value ? 1 : 0;
  if (value is String) return int.tryParse(value.trim());
  _rejectUnsupported(value);
}

double? coerceDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1.0 : 0.0;
  if (value is String) return double.tryParse(value.trim());
  _rejectUnsupported(value);
}

bool? coerceBool(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final text = value.trim().toLowerCase();
    if (text == 'true' || text == '1') return true;
    if (text == 'false' || text == '0') return false;
    return null;
  }
  _rejectUnsupported(value);
}

/// 单个字符串按逗号拆开，避免把 "action,comedy" 当成一个标签。
List<String> coerceStringList(dynamic value) {
  if (value == null) return const [];
  if (value is String) {
    return value
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  if (value is Iterable) {
    return value.map(coerceString).toList();
  }
  // 数字、布尔、Map 这类「是 JSON 值但不是列表」的写法，退化成空列表。
  if (value is num || value is bool || value is Map) return const [];
  _rejectUnsupported(value);
}

Map<String, String> coerceStringMap(dynamic value) {
  if (value == null) return const {};
  if (value is List || value is num || value is bool || value is String) {
    return const {};
  }
  if (value is! Map) _rejectUnsupported(value);
  final result = <String, String>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) continue;
    result[key] = coerceString(entry.value);
  }
  return result;
}
