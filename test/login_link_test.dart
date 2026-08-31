import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/login_link.dart';

void main() {
  group('parseLoginLink', () {
    test('parses and decodes custom-scheme login values', () {
      final values = parseLoginLink(
        Uri.parse(
          'wimsy://login?jid=alice%40example.org&password=p%26ss%2Bword'
          '&display_name=Alice%20Tester',
        ),
      );

      expect(values?.jid, 'alice@example.org');
      expect(values?.password, 'p&ss+word');
      expect(values?.displayName, 'Alice Tester');
    });

    test('parses the HTTPS login form', () {
      final values = parseLoginLink(
        Uri.parse(
          'https://wimsy.im/login?jid=bob%40example.org&password=secret'
          '&display_name=Bob',
        ),
      );

      expect(values?.jid, 'bob@example.org');
      expect(values?.password, 'secret');
      expect(values?.displayName, 'Bob');
    });

    test('rejects unrelated and JID-less links', () {
      expect(
        parseLoginLink(Uri.parse('https://example.org/login?jid=a@b')),
        isNull,
      );
      expect(
        parseLoginLink(Uri.parse('wimsy://login?password=secret')),
        isNull,
      );
    });
  });
}
