import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/settings/webdav_qr_payload.dart';

void main() {
  const payload = WebdavSyncQrPayload(
    url: 'https://dav.example.com/remote.php/webdav/',
    user: 'alice',
    pass: 's3cr3t:p@ss/word?=',
    excludedFields: 'theme,language',
    mode: 'scheduled',
    intervalMinutes: 60,
  );

  test('round-trip：特殊字符载荷编解码一致', () {
    final parsed = WebdavSyncQrPayload.tryParse(payload.toQrData());
    expect(parsed, isNotNull);
    expect(parsed!.url, payload.url);
    expect(parsed.user, payload.user);
    expect(parsed.pass, payload.pass);
    expect(parsed.excludedFields, payload.excludedFields);
    expect(parsed.mode, payload.mode);
    expect(parsed.intervalMinutes, payload.intervalMinutes);
    expect(parsed.isValid, isTrue);
  });

  test('空 url 判无效', () {
    const empty = WebdavSyncQrPayload(
      url: '  ',
      user: 'u',
      pass: 'p',
      excludedFields: '',
      mode: 'manual',
      intervalMinutes: 30,
    );
    expect(empty.isValid, isFalse);
    final parsed = WebdavSyncQrPayload.tryParse(empty.toQrData())!;
    expect(parsed.isValid, isFalse);
  });

  test('非 JSON / 类型错 / 版本错返回 null', () {
    expect(WebdavSyncQrPayload.tryParse('not json'), isNull);
    expect(WebdavSyncQrPayload.tryParse('["a","b"]'), isNull);
    expect(
      WebdavSyncQrPayload.tryParse(
        '{"type":"other","version":1,"webdav":{"url":"u","user":"u","pass":"p"}}',
      ),
      isNull,
    );
    expect(
      WebdavSyncQrPayload.tryParse(
        '{"type":"venera-unified.webdav-sync","version":999,"webdav":{"url":"u","user":"u","pass":"p"}}',
      ),
      isNull,
    );
    expect(
      WebdavSyncQrPayload.tryParse(
        '{"type":"venera-unified.webdav-sync","version":1}',
      ),
      isNull,
    );
    // 必填字段类型不对
    expect(
      WebdavSyncQrPayload.tryParse(
        '{"type":"venera-unified.webdav-sync","version":1,"webdav":{"url":1,"user":"u","pass":"p"}}',
      ),
      isNull,
    );
  });

  test('可选字段缺失或非法时回落默认值', () {
    final parsed = WebdavSyncQrPayload.tryParse(
      '{"type":"venera-unified.webdav-sync","version":1,'
      '"webdav":{"url":"https://x/","user":"u","pass":"p",'
      '"mode":"bogus","intervalMinutes":-5}}',
    )!;
    expect(parsed.excludedFields, '');
    expect(parsed.mode, 'manual');
    expect(parsed.intervalMinutes, 30);
  });

  test('三种 mode 都能 round-trip', () {
    for (final mode in ['manual', 'realtime', 'scheduled']) {
      final data = WebdavSyncQrPayload(
        url: 'https://x/',
        user: 'u',
        pass: 'p',
        excludedFields: '',
        mode: mode,
        intervalMinutes: 15,
      ).toQrData();
      expect(WebdavSyncQrPayload.tryParse(data)!.mode, mode);
    }
  });
}
