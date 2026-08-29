import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/jid_normalization.dart';

void main() {
  test('normalizes an entered bare JID', () {
    expect(
      normalizeEnteredJid('  Alice@EXAMPLE.COM  ', bare: true),
      'alice@example.com',
    );
  });

  test('preserves resource case', () {
    expect(
      normalizeEnteredJid('Alice@EXAMPLE.COM/Phone-A'),
      'alice@example.com/Phone-A',
    );
  });

  test('rejects an incomplete JID', () {
    expect(normalizeEnteredJid('example.com'), isNull);
  });
}
