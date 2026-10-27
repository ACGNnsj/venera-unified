/// 书源脚本返回的字段类型经常写错（数字当字符串、单个字符串当列表、时间戳当
/// 字符串等）。下面这组转换只做归一化，不改正常数据的语义，目的是让 `fromJson`
/// 不再因为一个字段类型不对就抛 TypeError。
///
/// 这些函数刻意不依赖任何其它模块，方便 `models.dart` 直接 import。
String coerceString(dynamic value, {String fallback = ''}) {
  if (value == null) return fallback;
  if (value is String) return value;
  return value.toString();
}

String? coerceNullableString(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

int? coerceInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().trim());
}

double? coerceDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().trim());
}

bool? coerceBool(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value.toString().trim().toLowerCase();
  if (text == 'true' || text == '1') return true;
  if (text == 'false' || text == '0') return false;
  return null;
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
    return value.map((e) => coerceString(e)).toList();
  }
  return const [];
}

Map<String, String> coerceStringMap(dynamic value) {
  if (value is! Map) return const {};
  final result = <String, String>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) continue;
    result[key] = coerceString(entry.value);
  }
  return result;
}
