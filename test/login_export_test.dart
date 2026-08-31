import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/login_export.dart';

void main() {
  test('builds a same-origin handoff URL with encoded login settings', () {
    final uri = buildAndroidLoginExportUri(
      webAppUri: Uri.parse('https://chat.example.org/app/#/room'),
      jid: 'tester@example.org',
      password: 'p&ss+word',
      displayName: 'Test Person',
    );

    expect(uri.origin, 'https://chat.example.org');
    expect(uri.path, '/open-wimsy.html');
    expect(uri.queryParameters['jid'], 'tester@example.org');
    expect(uri.queryParameters['password'], 'p&ss+word');
    expect(uri.queryParameters['display_name'], 'Test Person');
  });

  test('omits an empty display name', () {
    final uri = buildAndroidLoginExportUri(
      webAppUri: Uri.parse('http://localhost:8080/'),
      jid: 'tester@example.org',
      password: 'secret',
      displayName: ' ',
    );

    expect(uri.queryParameters, isNot(contains('display_name')));
  });
}
