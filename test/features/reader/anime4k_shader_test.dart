import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/reader/anime4k_shader.dart';

void main() {
  group('Anime4KShader gating', () {
    test('asset path points at the declared shader', () {
      expect(Anime4KShader.assetPath, 'shaders/anime4k_push.frag');
    });

    test('strength matches the native default', () {
      expect(Anime4KShader.strength, closeTo(1 / 3, 1e-9));
    });

    test('normal page sizes are eligible', () {
      expect(Anime4KShader.isEligibleSize(1200, 1800), isTrue);
      expect(Anime4KShader.isEligibleSize(4096, 4096), isTrue);
    });

    test('oversized textures are skipped', () {
      expect(Anime4KShader.isEligibleSize(4097, 100), isFalse);
      expect(Anime4KShader.isEligibleSize(100, 5000), isFalse);
    });

    test('degenerate sizes are skipped', () {
      expect(Anime4KShader.isEligibleSize(0, 100), isFalse);
      expect(Anime4KShader.isEligibleSize(-1, 100), isFalse);
    });
  });
}
