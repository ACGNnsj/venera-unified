import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/network/host_pacing.dart';

void main() {
  test('default table carries the pixiv hosts', () {
    final pacing = HostPacingInterceptor();
    expect(
      pacing.intervalFor('app-api.pixiv.net'),
      const Duration(milliseconds: 300),
    );
    expect(
      pacing.intervalFor('www.pixiv.net'),
      const Duration(milliseconds: 300),
    );
    expect(pacing.intervalFor('i.pximg.net'), const Duration(milliseconds: 50));
    expect(pacing.intervalFor('s.pximg.net'), const Duration(milliseconds: 50));
    expect(pacing.intervalFor('example.com'), Duration.zero);
  });

  test('unlisted hosts pass without delay', () async {
    final pacing = HostPacingInterceptor();
    final stopwatch = Stopwatch()..start();
    await pacing.pace(Uri.parse('https://example.com/a'));
    await pacing.pace(Uri.parse('https://example.com/b'));
    stopwatch.stop();
    expect(stopwatch.elapsedMilliseconds, lessThan(100));
  });

  test('same host back-to-back respects the interval', () async {
    final pacing = HostPacingInterceptor(
      intervals: const {'example.com': Duration(milliseconds: 120)},
    );
    final uri = Uri.parse('https://example.com/a');
    await pacing.pace(uri);
    final stopwatch = Stopwatch()..start();
    await pacing.pace(uri);
    stopwatch.stop();
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(90));
  });

  test('concurrent same-host slots serialize', () async {
    final pacing = HostPacingInterceptor(
      intervals: const {'example.com': Duration(milliseconds: 100)},
    );
    final uri = Uri.parse('https://example.com/a');
    final stopwatch = Stopwatch()..start();
    await Future.wait([pacing.pace(uri), pacing.pace(uri), pacing.pace(uri)]);
    stopwatch.stop();
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(150));
  });

  test('cross hosts do not block each other', () async {
    final pacing = HostPacingInterceptor(
      intervals: const {
        'a.example.com': Duration(milliseconds: 200),
        'b.example.com': Duration(milliseconds: 200),
      },
    );
    final stopwatch = Stopwatch()..start();
    await Future.wait([
      pacing.pace(Uri.parse('https://a.example.com/1')),
      pacing.pace(Uri.parse('https://b.example.com/1')),
    ]);
    stopwatch.stop();
    expect(stopwatch.elapsedMilliseconds, lessThan(150));
  });
}
