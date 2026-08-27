import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/login_screen.dart';

void main() {
  group('initialLoginJid', () {
    test('prefers the cached JID over account and web deployment values', () {
      expect(
        initialLoginJid(
          cachedJid: 'last-used@example.com',
          accountJid: 'stored@example.com',
          deploymentJid: 'default@example.com',
          isWeb: true,
        ),
        'last-used@example.com',
      );
    });

    test('falls back to the stored account JID', () {
      expect(
        initialLoginJid(
          cachedJid: null,
          accountJid: 'stored@example.com',
          deploymentJid: 'default@example.com',
          isWeb: true,
        ),
        'stored@example.com',
      );
    });

    test('uses the deployment JID only as a web fallback', () {
      expect(
        initialLoginJid(
          cachedJid: '',
          accountJid: null,
          deploymentJid: 'default@example.com',
          isWeb: true,
        ),
        'default@example.com',
      );
      expect(
        initialLoginJid(
          cachedJid: '',
          accountJid: null,
          deploymentJid: 'default@example.com',
          isWeb: false,
        ),
        isEmpty,
      );
    });
  });
}
