import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/settings/app_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a platform without a local_auth implementation reads as unsupported',
    () async {
      // The test VM registers no local_auth handler, which is the same thing
      // HarmonyOS looks like: the probe must answer false, not throw into the
      // settings page.
      expect(await supportsAuthorization(), isFalse);
    },
  );
}
