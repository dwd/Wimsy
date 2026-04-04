import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/quic_xmpp_socket.dart';

void main() {
  group('extractToBareJidForRouting', () {
    test('extracts bare jid from full jid in to attribute', () {
      const stanza = '<message to="room@example.com/nick" id="m1"/>';
      expect(extractToBareJidForRouting(stanza), 'room@example.com');
    });

    test('returns null when no to attribute exists', () {
      const stanza = '<a xmlns="urn:xmpp:sm:3" h="10"/>';
      expect(extractToBareJidForRouting(stanza), isNull);
    });

    test('supports single-quoted to attribute', () {
      const stanza = "<presence to='romeo@example.net/resource'/>";
      expect(extractToBareJidForRouting(stanza), 'romeo@example.net');
    });
  });

  group('bareJidForRouting', () {
    test('strips resource', () {
      expect(
        bareJidForRouting('juliet@example.com/balcony'),
        'juliet@example.com',
      );
    });

    test('keeps bare jid unchanged', () {
      expect(
        bareJidForRouting('room@conference.example.org'),
        'room@conference.example.org',
      );
    });
  });

  group('quicAuxSlotForBareJid', () {
    test('is deterministic for the same jid', () {
      final first = quicAuxSlotForBareJid('room@example.com', 20);
      final second = quicAuxSlotForBareJid('room@example.com', 20);
      expect(first, second);
    });

    test('stays within bounds', () {
      final slot = quicAuxSlotForBareJid('contact@example.com', 20);
      expect(slot, inInclusiveRange(0, 19));
    });
  });
}
