import 'dart:convert';

/// QR-shareable snapshot of the app-data WebDAV sync configuration.
///
/// Wire format (JSON):
/// ```json
/// {
///   "type": "venera-unified.webdav-sync",
///   "version": 1,
///   "webdav": {
///     "url": "...", "user": "...", "pass": "...",
///     "excludedFields": "...",
///     "mode": "manual|realtime|scheduled",
///     "intervalMinutes": 30
///   }
/// }
/// ```
/// Pure Dart on purpose: no Flutter import, so the codec is unit-testable
/// without a widget binding. The QR code embeds the password in cleartext;
/// the UI must warn before showing it.
class WebdavSyncQrPayload {
  const WebdavSyncQrPayload({
    required this.url,
    required this.user,
    required this.pass,
    required this.excludedFields,
    required this.mode,
    required this.intervalMinutes,
  });

  static const String qrType = 'venera-unified.webdav-sync';
  static const int qrVersion = 1;
  static const Set<String> validModes = {'manual', 'realtime', 'scheduled'};

  final String url;
  final String user;
  final String pass;
  final String excludedFields;

  /// One of [validModes]; mirrors `DataSyncMode.name`.
  final String mode;
  final int intervalMinutes;

  bool get isValid => url.trim().isNotEmpty;

  String toQrData() {
    return jsonEncode({
      'type': qrType,
      'version': qrVersion,
      'webdav': {
        'url': url,
        'user': user,
        'pass': pass,
        'excludedFields': excludedFields,
        'mode': mode,
        'intervalMinutes': intervalMinutes,
      },
    });
  }

  static WebdavSyncQrPayload? tryParse(String data) {
    try {
      final json = jsonDecode(data);
      if (json is! Map ||
          json['type'] != qrType ||
          json['version'] != qrVersion ||
          json['webdav'] is! Map) {
        return null;
      }
      final webdav = json['webdav'] as Map;
      final url = webdav['url'];
      final user = webdav['user'];
      final pass = webdav['pass'];
      if (url is! String || user is! String || pass is! String) {
        return null;
      }
      final excludedFields = webdav['excludedFields'];
      final mode = webdav['mode'];
      final intervalMinutes = webdav['intervalMinutes'];
      return WebdavSyncQrPayload(
        url: url,
        user: user,
        pass: pass,
        excludedFields: excludedFields is String ? excludedFields : '',
        mode: mode is String && validModes.contains(mode) ? mode : 'manual',
        intervalMinutes: intervalMinutes is int && intervalMinutes > 0
            ? intervalMinutes
            : 30,
      );
    } catch (_) {
      return null;
    }
  }
}
